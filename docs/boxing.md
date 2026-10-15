# Boxing the reference client (Wine pipeline)

This is the reproducible pipeline for DESIGN.md §10 ("Hosting the reference") and
roadmap step 1, the **Wine spike** (§13.1): box the official KakaoTalk Windows
client under Wine in a container and prove it launches headlessly. The grey-box
taps (§5.2) are a later, reviewed step — the [`patches/`](../patches/) seam is
empty for now.

## Quick start

```sh
make fetch    # download the pinned x64 installer into vendor/ and verify its SHA256
make build    # build the image: Debian + Wine, client installed into the prefix
make run      # launch spike: PASS if the client runs under Wine headlessly
make shell    # interactive shell in the image to poke at the prefix
```

`make build` depends on `make fetch`, so `make build` alone is enough after a
clean checkout.

## What is pinned, and how

| Thing | Pin | Where |
|-------|-----|-------|
| Installer bytes | SHA256 | [`../SHA256SUMS`](../SHA256SUMS), checked by `make verify` |
| Debian base | manifest digest | `DEBIAN_DIGEST` in [`../Dockerfile`](../Dockerfile) |
| Wine | exact WineHQ apt version | `WINE_VERSION` in the Dockerfile |
| winetricks | release tag | `WINETRICKS_VERSION` in the Dockerfile |

The installer itself is **never committed** (it is proprietary; see DESIGN §11).
Only its SHA256 is tracked. `vendor/` is gitignored.

### The installer URL is a rolling "latest"

`https://app-pc.kakaocdn.net/talk/win32/x64/KakaoTalk_Setup.exe` has no version in
its path — it always serves the current build. So "pinned" means the bytes must
match `SHA256SUMS`. When Kakao ships a new client, `make fetch` fails with a
checksum mismatch. **That is by design** (DESIGN §9): a new upstream build is a
deliberate re-baseline event, not a silent upgrade.

## Re-baselining on a new client release

```sh
make rebaseline   # re-download, rewrite SHA256SUMS
```

Then review and commit the new `SHA256SUMS`, rebuild, and **re-baseline any
grey-box taps** — tap offsets move every release (DESIGN §12).

## Reproducibility notes

- The hard pins (installer bytes, base image digest, Wine version, winetricks tag)
  are exact. `apt-get update` for the WineHQ/Debian repos still reaches live
  mirrors, so transitive apt dependencies are only as reproducible as those
  mirrors at build time — acceptable for a bench oracle, and documented here.
- Scripts live under [`../docker/`](../docker/): `box-install.sh` (build-time
  silent install), `entrypoint.sh` (headless X + tap seam), `verify-launch.sh`
  (the spike's pass/fail check).

## Prefix snapshot / restore (Tier 1 containment)

The filesystem/DB, the Wine registry, and the synthesized device identity all
live inside `$WINEPREFIX`, so one archive snapshots all three "Snapshot" channels
of DESIGN §5.1 at once. Three scripts (shipped in the image at
`/usr/local/bin/`, source under [`../docker/`](../docker/)) implement the
"restore to a known baseline before each run, diff after" loop from
[`containment.md`](containment.md):

```sh
# capture a clean baseline (e.g. right after a fresh boot, before login)
prefix-snapshot.sh /work/baseline.tar

# ... drive the client through a scenario ...

# see what it persisted (paths added / removed / size-changed)
prefix-diff.sh /work/baseline.tar            # fast: path + size
prefix-diff.sh /work/baseline.tar --hash     # also content (sha256)

# reset the prefix to the baseline for the next run
prefix-restore.sh /work/baseline.tar
```

- `prefix-snapshot.sh` writes a deterministic tar (sorted, zeroed owner/mtime) so
  an unchanged prefix hashes identically run to run. It does not modify the prefix.
- `prefix-restore.sh` stops `wineserver`, extracts to a staging dir, then swaps —
  a failed extraction leaves the old prefix intact. It refuses obviously wrong
  targets (`/`, `/home`, `$HOME`).
- `prefix-diff.sh` reports `+ added`, `- removed`, `~ changed` paths; it is
  path+size/hash level only. Decoding the records themselves is the Tier 2 storage
  tap (future work).

### State-only snapshots (`prefix-state.sh`)

A full prefix snapshot is ~1.5 GB / ~13 s uncompressed on the current client,
because almost all of it is immutable base — Wine's own `C:\windows` (~1.4 GB) and
the installed client (~135 MB), which are identical every run and already live in
the image's read-only layers. The only state the client's output actually depends
on is the **registry + the Kakao app-data tree: ~3 MB.** `prefix-state.sh` operates
on exactly that set:

```sh
prefix-state.sh snapshot /work/state.tar      # ~3 MB, not 1.5 GB
prefix-state.sh diff     /work/state.tar       # path+size; add --hash for content
prefix-state.sh restore  /work/state.tar       # resets state only; base untouched
```

The state set (single source of truth, in the script): `system.reg`, `user.reg`,
`userdef.reg`, and `drive_c/users/*/AppData/{Local,Roaming,LocalLow}/Kakao` (plus
`drive_c/ProgramData/Kakao` if present); `Temp` is excluded as run noise. `restore`
clears those paths and extracts the baseline over them, leaving the base in place —
verified: a tampered base file survives a state restore.

Use `prefix-state.sh` for the per-run snapshot/restore/diff loop. Use the
full-prefix `prefix-snapshot.sh` only to re-baseline the whole box on a new client
release (DESIGN §9).

**Is the state set complete?** It is a *declared* set, validated by observation —
see "Validating the state set" in [`containment.md`](containment.md) for the
method, and `prefix-trace.sh` below for the implementation.

### Validating the state set at runtime (`prefix-trace.sh`)

The snapshot/diff tools above show what the client *wrote*. They cannot show what
it *read* — including reads of paths we never provisioned (a probe for a missing
file is itself a signal). `prefix-trace.sh` closes that gap: it launches the
boxed client, records every file and registry access, and classifies each one, so
the claim "the state set is the only state-bearing thing the client reads" becomes
checkable rather than assumed.

```sh
# default: WINEDEBUG trace of a ~20s headless launch (no login), then report
prefix-trace.sh

prefix-trace.sh --seconds 30            # longer exercise window
prefix-trace.sh --keep --out /work      # retain the raw log under /work
prefix-trace.sh --strict                # exit non-zero if anything is "unexpected"
prefix-trace.sh --mode strace           # ptrace ground truth (caveat below)
prefix-trace.sh --mode bpftrace         # eBPF ground truth (needs CAP_BPF)
```

It reuses `prefix-state.sh`'s `STATE_GLOBS` as the single source of truth (it
`source`s the script; the state set is never redefined), and buckets every access
as:

- **base** — immutable Wine/client install (`C:\windows`, the installed client
  under `Program Files\Kakao`, the host Wine runtime, Wine's XDG desktop
  integration). Expected, ignorable.
- **state** — inside the declared state set (registry hives + the Kakao AppData /
  ProgramData trees, and the ancestor dirs traversed to reach them). Covered.
- **host-env** — clock / RNG / locale / timezone / fonts / DNS / run-noise
  (`/dev/urandom`, `/etc/localtime`, `/usr/share/fonts`, `Temp`, …), neutralized by
  the other Tier-1 seams (DESIGN §5.1). Expected.
- **unexpected** — everything else. This is the list to read: anything here is a
  state-, identity-, or determinism-bearing read that the state set does not cover,
  *or* benign noise (pre-login known-folder probes such as `Desktop`/`Downloads`,
  bare drive-root traversal) — confirm each.

The report prints per-bucket counts and the full "unexpected" list. On the current
pre-login client the useful catch is that the client probes a **compiled-in
OpenSSL config/CA path from its build machine** (`C:\kakao\work\vcpkg\…\openssl.cnf`,
`cert.pem`) that does not exist in the prefix — exactly the kind of determinism-
relevant read worth knowing about, surfaced rather than hidden.

#### Methods and the anti-tamper caveat

| `--mode` | How | Anti-tamper risk |
|----------|-----|------------------|
| `winedebug` (default) | `WINEDEBUG=+file,+reg`; Wine logs resolved paths itself | **None** — no `ptrace`, nothing attaches to the protected process |
| `strace` | `strace -f` on file syscalls | **Attaches via `ptrace`** — the Themida-family protector may treat it as a debugger (see [`containment.md`](containment.md) "Anti-tamper"); treat any behavior change as itself a signal |
| `bpftrace` | eBPF on the `openat` tracepoint | None (ptrace-free), but needs a privileged / `CAP_BPF` container and `bpftrace` in the image |

`strace`/`bpftrace` are not installed in the image by default; those modes fail
with a clear message rather than silently. `winedebug` is the primary method
precisely because it is the lowest-risk against the protector.

**Safety (DESIGN §11).** The client is never logged in. The raw trace log is a
capture artifact: it is written to a temp dir and deleted unless `--keep`, and
must never be committed.

### Enforcing the state set (`prefix-guard.sh`)

`prefix-trace.sh` *observes*; `prefix-guard.sh` *enforces*. It turns "is the state
set complete?" into an invariant the box upholds at runtime: any file access
outside the declared set crashes the client. This is method (4) of
[`containment.md`](containment.md)'s "Validating the state set". Two out-of-process
layers (no `ptrace`, anti-tamper-safe), both needing a **privileged /
`CAP_SYS_ADMIN`** container:

1. **Structural read-only base.** The immutable install (`drive_c/windows`,
   `drive_c/Program Files`) is bind-remounted **read-only**, so a write outside the
   state set fails `EROFS` and an unprovisioned base read fails `ENOENT`. The prefix
   is first bind-mounted to itself, which also bounds the guard's scope to the
   prefix subtree.
2. **Active `fanotify` guard** (`prefix-guard.py`). Intercepts every open in the
   writable region via `FAN_OPEN_PERM`, classifies it against the state set, and on
   any off-list access **`SIGKILL`s the whole client process tree** — a hard crash —
   or logs it under `--log-only`.

```sh
# must be root; e.g.
docker run --rm --privileged -u 0 <image> prefix-guard.sh              # kill mode (default)
docker run --rm --privileged -u 0 <image> prefix-guard.sh --log-only   # observe, don't kill
docker run --rm --privileged -u 0 <image> prefix-guard.sh --allow-extra 'drive_c/foo/*'
#   --seconds N     launch-hold window      --no-readonly   skip the ro base layer
```

Like `prefix-trace.sh` it reuses `prefix-state.sh`'s `STATE_GLOBS` as the single
source of truth (the wrapper `source`s it and passes the globs to the guard). The
base and known-benign allow rules are the guard's own policy: the benign seed is
exactly the pre-login residue `prefix-trace.sh` surfaces (`Desktop`/`Downloads`
known-folder probes, the compiled-in OpenSSL build path), so the **unmodified**
client runs clean under the default kill mode and only a *genuinely new* access
crashes it.

**Converge first.** A too-tight allowlist crashes the client on a legitimate read.
The workflow is: run `prefix-trace.sh`, fold any benign "unexpected" into the
allowlist (`--allow-extra`, or the seed in `prefix-guard.py`), *then* enable kill
mode. The guard exits non-zero (3) on a violation, so CI can gate on it.

**Caveat.** `fanotify` and the read-only bind-remounts need `CAP_SYS_ADMIN`; the
guard refuses to run unless it is root and prints how to launch the container. This
is the same privilege class as the `bpftrace` trace mode — the trade for a
kernel-level, anti-tamper-safe enforcement point.

### Future: a layered prefix

`prefix-guard.sh` already enforces a read-only base in place; the remaining
structural step splits the prefix into separately-mounted layers. It follows the
Matrix–WeChat `wechat-box` precedent (immutable Wine base image + mounted-in
payloads):

The state-only tool makes the snapshot loop cheap, but the prefix is still one
directory. The structural version splits it, following the Matrix–WeChat
`wechat-box` precedent (immutable Wine base image + mounted-in payloads):

- **Immutable lower layer** — Wine + installed client, baked into the image,
  mounted **read-only**. A read-only base is also what makes "did the client try to
  write/read outside its state?" observable (an `EACCES`/`EROFS` is a signal).
- **Writable upper layer** — the state set, on a real volume or `tmpfs` (not on the
  container's own overlay — overlay-on-overlay fails; keep frequently-written state
  on a volume). Snapshot/restore then touches only this small layer.
- **A dedicated payload dir** (e.g. `drive_c/injector/`, as `injector-box` uses) for
  a future grey-box tap DLL, so a version-matched tap drops in and is swapped with
  zero prefix churn.

This pairs naturally with the network-interpose / clock-RNG work and pre-positions
the Tier 2 payload dir. Not built yet; tracked in `containment.md`'s roadmap.

## Scope and safety

`verify-launch.sh` stops at "the process launches and stays up." It does **not**
attempt login — that needs a disposable, owned test account and is done manually
(DESIGN §11). No credentials, captures, or device identifiers belong in the image
or the repo.
