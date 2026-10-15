#!/usr/bin/env python3
"""Active state-whitelist guard for the Wine-boxed reference client (Tier 1).

docs/containment.md "Validating the state set", method (4) -- enforce, don't just
observe. Where prefix-trace.sh *reports* what the client reads, this *enforces* it:
it intercepts every file open inside the Wine prefix via fanotify FAN_OPEN_PERM
and, for any access that is not in the declared state set (or the immutable base /
a known-benign path), it SIGKILLs the client -- a hard crash on an off-list read --
or just logs it under --log-only.

Why fanotify and not ptrace: fanotify is a kernel facility, out-of-process. It does
NOT attach to or modify the protected process, so the Themida-family anti-tamper
(containment.md "Anti-tamper") cannot see it -- unlike strace/ptrace. Cost: it needs
CAP_SYS_ADMIN (a privileged container).

Scope: the guard marks the prefix *mount* (prefix-guard.sh bind-mounts the prefix to
itself so the mark covers only the prefix subtree, not the whole container rootfs).
The immutable base (drive_c/windows, drive_c/Program Files) is bind-remounted
read-only by the wrapper and thus lives on its own sub-mounts whose opens never reach
this mark -- base reads are implicitly allowed and base writes fail with EROFS. So the
enforced region is exactly the writable part of the prefix, where state lives.

The state set is NOT redefined here: the wrapper sources prefix-state.sh and passes
its STATE_GLOBS via --state-glob. Base and known-benign allow rules below are this
tool's own policy (the benign seed = the pre-login residue prefix-trace.sh surfaces,
so the UNMODIFIED client runs clean under --kill and only a genuinely NEW access
crashes it). Converge the allowlist with prefix-trace.sh first; add operator
exceptions with --allow-extra.

Lab tooling only (DESIGN §11): never logs in; prints paths, never file contents.
"""
import argparse
import ctypes
import fnmatch
import os
import select
import signal
import struct
import sys
import time

# --- fanotify constants (uapi/linux/fanotify.h) --------------------------------
FAN_CLOEXEC = 0x1
FAN_NONBLOCK = 0x2
FAN_CLASS_CONTENT = 0x4
FAN_MARK_ADD = 0x1
FAN_MARK_MOUNT = 0x10
FAN_OPEN_PERM = 0x00010000
FAN_ALLOW = 0x1
FAN_DENY = 0x2
FANOTIFY_METADATA_VERSION = 3
_META = "=IBBHQii"               # event_len,vers,reserved,metadata_len,mask,fd,pid
_META_SZ = struct.calcsize(_META)   # 24
_RESP = "=iI"                    # fd, response

# Immutable Wine/client install inside the prefix: always allowed. (Normally these
# are read-only sub-mounts whose opens never even reach our mark; listed anyway so
# the guard is correct when run without the read-only layering.)
BASE_GLOBS = [
    "drive_c/windows", "drive_c/windows/*",
    "drive_c/Program Files", "drive_c/Program Files/*",
    "drive_c/Program Files (x86)", "drive_c/Program Files (x86)/*",
    "drive_c/ProgramData", "drive_c/ProgramData/*",
    ".", ".update-timestamp", ".windows-*",
    "system.reg", "user.reg", "userdef.reg",   # also in STATE_GLOBS; harmless dup
]

# Ancestor dirs the client stats on the way to its state trees: traversal, allowed.
ANCESTOR_GLOBS = [
    "drive_c", "drive_c/users", "drive_c/users/*",
    "drive_c/users/*/AppData", "drive_c/users/*/AppData/Local",
    "drive_c/users/*/AppData/Roaming", "drive_c/users/*/AppData/LocalLow",
]

# Known-benign pre-login residue that prefix-trace.sh surfaces as "unexpected" but is
# not state-bearing. Seeded so the unmodified client runs clean under --kill. Review
# and trim per scenario; add more with --allow-extra.
BENIGN_GLOBS = [
    # Shell known-folders the client enumerates (empty pre-login).
    "drive_c/users/*/Desktop", "drive_c/users/*/Desktop/*",
    "drive_c/users/*/Downloads", "drive_c/users/*/Downloads/*",
    "drive_c/users/*/Documents", "drive_c/users/*/Documents/*",
    "drive_c/users/*/Pictures", "drive_c/users/*/Pictures/*",
    "drive_c/users/*/Music", "drive_c/users/*/Music/*",
    "drive_c/users/*/Videos", "drive_c/users/*/Videos/*",
    "drive_c/users/*/Temp", "drive_c/users/*/Temp/*",
    "drive_c/users/*/AppData/Local/Temp", "drive_c/users/*/AppData/Local/Temp/*",
    # Compiled-in OpenSSL config/CA path from the client's build machine (absent
    # from the prefix; a harmless ENOENT probe -- see prefix-trace.sh output).
    "drive_c/kakao", "drive_c/kakao/*",
]


def _libc():
    lib = ctypes.CDLL("libc.so.6", use_errno=True)
    return lib


def fanotify_init(lib, flags, event_f_flags):
    r = lib.fanotify_init(flags, event_f_flags)
    if r < 0:
        e = ctypes.get_errno()
        raise OSError(e, "fanotify_init: " + os.strerror(e))
    return r


def fanotify_mark(lib, fd, flags, mask, dirfd, path):
    r = lib.fanotify_mark(fd, flags, ctypes.c_uint64(mask), dirfd,
                          path.encode() if path else None)
    if r < 0:
        e = ctypes.get_errno()
        raise OSError(e, "fanotify_mark(%s): %s" % (path, os.strerror(e)))
    return r


def _subtree(globs):
    """Expand each glob to 'the dir itself' + 'everything under it'. Used for
    state/base/benign rules where matching a directory means its whole subtree.
    Ancestor rules are NOT expanded this way (they allow the exact dir only), so a
    bare 'drive_c' does not whitelist all of drive_c/*."""
    out = []
    for g in globs:
        out.append(g)
        if not g.endswith("/*"):
            out.append(g + "/*")
    return out


class Classifier:
    def __init__(self, prefix, state_globs, allow_extra):
        self.prefix = os.path.realpath(prefix).rstrip("/")
        self.state = _subtree(state_globs)
        self.allow = self.state + _subtree(BASE_GLOBS) + ANCESTOR_GLOBS + \
            _subtree(BENIGN_GLOBS) + _subtree(allow_extra)

    def to_rel(self, abspath):
        """Absolute host path -> prefix-relative, or None if outside the prefix."""
        p = abspath.rstrip("/")
        if p == self.prefix:
            return "."
        if p.startswith(self.prefix + "/"):
            return p[len(self.prefix) + 1:]
        return None

    @staticmethod
    def _match(rel, globs):
        return any(fnmatch.fnmatch(rel, g) for g in globs)

    def verdict(self, abspath):
        """Return (allowed, rel, is_state). Paths outside the prefix are allowed
        (not our enforced region)."""
        rel = self.to_rel(abspath)
        if rel is None:
            return True, abspath, False
        if self._match(rel, self.state):
            return True, rel, True
        return self._match(rel, self.allow), rel, False


def drop_privs_and_exec(exe, uid, gid):
    """Child: become the unprivileged wine user, start a new session, exec wine."""
    os.setsid()
    try:
        os.setgroups([gid])
    except OSError:
        pass
    os.setgid(gid)
    os.setuid(uid)
    env = dict(os.environ)
    env.setdefault("HOME", "/home/wine")
    env["WINEDEBUG"] = "-all"
    os.execvpe("wine", ["wine", exe], env)


def main():
    ap = argparse.ArgumentParser(description="fanotify state-whitelist guard")
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--state-glob", action="append", default=[],
                    help="a state-set glob (from prefix-state.sh STATE_GLOBS)")
    ap.add_argument("--allow-extra", action="append", default=[],
                    help="additional allowed glob (operator exception)")
    ap.add_argument("--uid", type=int, default=1000)
    ap.add_argument("--gid", type=int, default=1000)
    ap.add_argument("--log-only", action="store_true",
                    help="log violations but allow them (do not kill)")
    args = ap.parse_args()

    if not args.state_glob:
        print("FAIL: no --state-glob given; refusing to run with an empty state set",
              file=sys.stderr)
        return 2

    clf = Classifier(args.prefix, args.state_glob, args.allow_extra)
    lib = _libc()

    # Mark the prefix mount for open-permission events BEFORE launching the client,
    # so no early open slips past the guard.
    fan = fanotify_init(lib, FAN_CLOEXEC | FAN_NONBLOCK | FAN_CLASS_CONTENT,
                        os.O_RDONLY)
    fanotify_mark(lib, fan, FAN_MARK_ADD | FAN_MARK_MOUNT, FAN_OPEN_PERM, -1,
                  args.prefix)

    mode = "LOG-ONLY" if args.log_only else "KILL-ON-VIOLATION"
    print(">> prefix-guard: %s  prefix=%s  exe=%s  hold=%ds"
          % (mode, args.prefix, args.exe, args.seconds), flush=True)

    child = os.fork()
    if child == 0:
        try:
            drop_privs_and_exec(args.exe, args.uid, args.gid)
        except Exception as exc:  # noqa: BLE001
            os.write(2, ("child exec failed: %r\n" % exc).encode())
            os._exit(127)

    me = os.getpid()
    allowed = 0
    violations = []           # (rel, pid)
    seen_bad = set()
    killed = False
    deadline = time.time() + args.seconds

    def stop_client():
        # The launcher's process group does not cover KakaoTalk.exe (Wine reparents
        # it under wineserver), so kill the whole wine-user process tree: that is
        # the client, wineserver and every Wine helper, and nothing else runs as
        # this uid in the box. This is the hard crash.
        try:
            os.killpg(child, signal.SIGKILL)
        except OSError:
            pass
        os.system("pkill -9 -u %d >/dev/null 2>&1 || true" % args.uid)

    while time.time() < deadline:
        # Reap the launcher if it exited (the client may live on via wineserver).
        try:
            wpid, _ = os.waitpid(child, os.WNOHANG)
        except OSError:
            wpid = 0
        r, _, _ = select.select([fan], [], [], 0.5)
        if not r:
            continue
        try:
            buf = os.read(fan, 16 * 4096)
        except BlockingIOError:
            continue
        off = 0
        resp = bytearray()
        while off + _META_SZ <= len(buf):
            elen, vers, _res, _mlen, mask, efd, epid = struct.unpack_from(_META, buf, off)
            off += elen
            if efd < 0:
                continue
            if vers != FANOTIFY_METADATA_VERSION:
                os.close(efd)
                continue
            try:
                path = os.readlink("/proc/self/fd/%d" % efd)
            except OSError:
                path = "?"
            decision = FAN_ALLOW
            if mask & FAN_OPEN_PERM:
                if epid == me:
                    decision = FAN_ALLOW            # never block the guard itself
                else:
                    ok, rel, _is_state = clf.verdict(path)
                    if ok:
                        allowed += 1
                    else:
                        if rel not in seen_bad:
                            seen_bad.add(rel)
                            violations.append((rel, epid))
                            print("VIOLATION pid=%d  %s" % (epid, rel), flush=True)
                        decision = FAN_ALLOW if args.log_only else FAN_DENY
                resp += struct.pack(_RESP, efd, decision)
            os.close(efd)
        if resp:
            os.write(fan, bytes(resp))
        if violations and not args.log_only and not killed:
            print("!! off-list access -> crashing the client (SIGKILL)", flush=True)
            stop_client()
            killed = True
            break

    stop_client()

    print("\n================ state-whitelist guard ================", flush=True)
    print("mode:        %s" % mode)
    print("prefix:      %s" % args.prefix)
    print("state globs: %d   allow rules: %d" % (len(args.state_glob), len(clf.allow)))
    print("opens allowed (in-prefix): %d" % allowed)
    print("distinct violations:       %d" % len(violations))
    if violations:
        print("RESULT: %s%d off-list access(es):"
              % ("(not enforced; --log-only) " if args.log_only else "", len(violations)))
        for rel, pid in violations:
            print("    pid=%d  %s" % (pid, rel))
        if not args.log_only:
            print("client was SIGKILLed on the first violation.")
    else:
        print("RESULT: no off-list access. Every in-prefix open was state, base, or")
        print("        a known-benign path -- the declared state set held.")
    print("=======================================================", flush=True)
    # Non-zero when the invariant was violated, so CI can gate on it.
    return 3 if (violations and not args.log_only) else 0


if __name__ == "__main__":
    sys.exit(main())
