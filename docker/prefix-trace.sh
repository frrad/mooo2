#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md, "Validating the state set"): prove the
# declared state set in prefix-state.sh is the ONLY state-bearing thing the boxed
# client reads, by enumerating what it actually accesses at runtime.
#
# This answers the question the snapshot/diff tools cannot: those show what the
# client *wrote*; this shows what it *read*, including reads of paths we never
# provisioned (a probe for a missing file is itself a signal). The useful output
# is not "what was touched" (fonts, RNG, DNS are all expected host noise) but "is
# anything state-, identity-, or determinism-bearing touched that the declared
# state set does not already cover" -> the "unexpected" bucket.
#
# Method (cheapest first; see docs/containment.md):
#   winedebug  WINEDEBUG=+file,+reg   -- DEFAULT. Wine logs every file open and
#              registry access with the resolved path, no ptrace, so it does not
#              perturb the Themida-family protected process. This is the primary
#              method.
#   strace     strace -f on file syscalls -- ground truth, but attaches via
#              ptrace; the protector may treat that as a debugger (containment.md
#              "Anti-tamper"). A behavior change under strace is itself a signal.
#   bpftrace   eBPF on the openat tracepoint -- authoritative, ptrace-free, but
#              needs a privileged (CAP_BPF) container and bpftrace installed.
#
# The state set is NOT redefined here: this script sources prefix-state.sh and
# reuses its STATE_GLOBS as the single source of truth.
#
# Lab tooling only (DESIGN §11): the client is NOT logged in and this never logs
# in. The raw trace log is treated as a capture artifact -- it is written to a
# temp dir and deleted unless --keep, and must never be committed.
#
# Usage:
#   prefix-trace.sh [--mode winedebug|strace|bpftrace] [--seconds N]
#                   [--exe PATH] [--out DIR] [--keep] [--strict]
set -euo pipefail

: "${WINEPREFIX:?WINEPREFIX must be set}"

# --- Reuse the state-set definition (single source of truth) --------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=prefix-state.sh
source "$HERE/prefix-state.sh"   # defines STATE_GLOBS (and state_paths, etc.)

# --- Args -----------------------------------------------------------------------
MODE=winedebug
SECONDS_HOLD="${LAUNCH_HOLD_SECONDS:-20}"
EXE=""
OUT=""
KEEP=0
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="${2:?}"; shift 2 ;;
    --seconds) SECONDS_HOLD="${2:?}"; shift 2 ;;
    --exe)     EXE="${2:?}"; shift 2 ;;
    --out)     OUT="${2:?}"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    --strict)  STRICT=1; shift ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "FAIL: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

# --- Locate the client (same discovery as verify-launch.sh) ---------------------
if [ -z "$EXE" ]; then
  # KAKAO_EXE is set by prefix-layer.sh run (the client's path inside the layer).
  EXE="${KAKAO_EXE:-$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)}"
  if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
    EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
  fi
fi
[ -n "$EXE" ] && [ -f "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }

# --- Work dir for the raw log (capture artifact; see header) --------------------
if [ -z "$OUT" ]; then OUT="$(mktemp -d)"; else mkdir -p "$OUT"; fi
LOG="$OUT/trace-${MODE}.log"
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$OUT"; }
trap cleanup EXIT

# --- Run the trace --------------------------------------------------------------
run_winedebug() {
  echo ">> winedebug trace: WINEDEBUG=+file,+reg  $EXE  (hold ${SECONDS_HOLD}s)" >&2
  WINEDEBUG=+file,+reg wine "$EXE" >"$LOG" 2>&1 &
  local wpid=$!
  sleep "$SECONDS_HOLD"
  wineserver -k >/dev/null 2>&1 || true
  wait "$wpid" 2>/dev/null || true
}

run_strace() {
  command -v strace >/dev/null 2>&1 || {
    echo "FAIL: strace not installed in the image. Install it, or use --mode winedebug." >&2
    echo "NOTE: strace attaches via ptrace; the protector may treat it as a debugger" >&2
    echo "      (docs/containment.md 'Anti-tamper'). Treat any behavior change as a signal." >&2
    exit 2
  }
  echo ">> strace trace (ptrace; anti-tamper caveat applies): $EXE (hold ${SECONDS_HOLD}s)" >&2
  strace -f -y -e trace=%file -o "$LOG" wine "$EXE" >/dev/null 2>&1 &
  local spid=$!
  sleep "$SECONDS_HOLD"
  wineserver -k >/dev/null 2>&1 || true
  kill "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
}

run_bpftrace() {
  command -v bpftrace >/dev/null 2>&1 || {
    echo "FAIL: bpftrace not installed. The bpftrace mode is the authoritative" >&2
    echo "      enumerator (ptrace-free, invisible to anti-debug) but needs:" >&2
    echo "        - bpftrace in the image, and" >&2
    echo "        - a privileged / CAP_BPF container (docker run --cap-add BPF ... or --privileged)." >&2
    echo "      See docs/containment.md 'Validating the state set' method 2." >&2
    exit 2
  }
  echo ">> bpftrace trace (eBPF openat; needs CAP_BPF): $EXE (hold ${SECONDS_HOLD}s)" >&2
  # Log every openat path opened by the wine process tree. Matching on comm is a
  # coarse filter; refine to the launched PID tree if the container is noisy.
  bpftrace -e '
    tracepoint:syscalls:sys_enter_openat
    /comm == "wine" || comm == "wine64" || comm == "KakaoTalk.exe" || strncmp(comm, "wine", 4) == 0/
    { printf("OPEN %s\n", str(args->filename)); }
  ' >"$LOG" 2>/dev/null &
  local bpid=$!
  sleep 1
  WINEDEBUG=-all wine "$EXE" >/dev/null 2>&1 &
  local wpid=$!
  sleep "$SECONDS_HOLD"
  wineserver -k >/dev/null 2>&1 || true
  wait "$wpid" 2>/dev/null || true
  kill "$bpid" 2>/dev/null || true
  wait "$bpid" 2>/dev/null || true
}

case "$MODE" in
  winedebug) run_winedebug ;;
  strace)    run_strace ;;
  bpftrace)  run_bpftrace ;;
  *) echo "FAIL: unknown --mode '$MODE' (winedebug|strace|bpftrace)" >&2; exit 1 ;;
esac

[ -s "$LOG" ] || { echo "FAIL: trace produced no output ($LOG). Did the client launch?" >&2; exit 1; }

# --- Extract accessed paths from the raw log -----------------------------------
# Output of each extractor: lines "<channel>\t<logical-path>", where channel is
# FILE or REG, and logical-path is normalized to be classifiable:
#   - prefix paths   -> "drive_c/..." or a prefix-root file ("system.reg")
#   - host paths     -> "/..."
#   - registry paths -> "Machine/..." / "User/..." (hive-rooted)
#
# Wine trace line format is "<tid>:trace:<channel>:<func> <args>". We key off the
# ":file:" / ":reg:" tags and pull path-looking tokens. Backslash runs in NT
# paths are collapsed to single slashes so single-vs-double-backslash output does
# not matter.
# RAW holds "<form>\t<channel>\t<token>" where form is U (unix path), N (NT path)
# or R (registry hive-rooted path). Extraction below is pure grep/sed (no per-line
# shell forks) so it scales to the ~300k-line log; normalization/classification
# then runs only over the de-duplicated token set (a few hundred), which is fast.
RAW="$OUT/accesses.raw"
: >"$RAW"

# Normalize a unix path (resolved target, strace path, or bpftrace path) to a
# logical path. Paths under $WINEPREFIX become prefix-relative; the dosdevices
# drive symlinks are unwound (c: -> drive_c, z: -> host root "/").
norm_unix() {
  local u="$1" rest
  case "$u" in
    "$WINEPREFIX"/dosdevices/[A-Za-z]:/*)
      rest="${u#"$WINEPREFIX"/dosdevices/}"           # e.g. c:/Program Files/...
      local d="${rest%%:/*}"; rest="${rest#[A-Za-z]:/}"
      case "$d" in
        [Cc]) printf 'drive_c/%s\n' "$rest" ;;
        [Zz]) printf '/%s\n' "$rest" ;;               # Z: == host root
        *)    printf 'drive_%s/%s\n' "${d,,}" "$rest" ;;
      esac ;;
    "$WINEPREFIX"/dosdevices/[A-Za-z]:) printf 'drive_c\n' ;;
    "$WINEPREFIX"/*) printf '%s\n' "${u#"$WINEPREFIX"/}" ;;   # drive_c/..., system.reg
    "$WINEPREFIX")   printf '.\n' ;;
    *) printf '%s\n' "$u" ;;                          # host absolute
  esac
}

# Normalize an NT path (e.g. \??\C:\windows\...) to a logical path.
norm_nt() {
  local p="$1"
  p="$(printf '%s' "$p" | sed -E 's#\\+#/#g; s#/+#/#g; s#^/\?\?/##; s#^/##')"
  case "$p" in
    [Cc]:/*) printf 'drive_c/%s\n' "${p#[A-Za-z]:/}" ;;
    [Zz]:/*) printf '/%s\n' "${p#[A-Za-z]:/}" ;;
    [A-Za-z]:/*) local d="${p%%:/*}"; printf 'drive_%s/%s\n' "${d,,}" "${p#[A-Za-z]:/}" ;;
    *) return 0 ;;   # not a drive path; ignore
  esac
}

extract_winedebug() {
  # (A) resolved unix targets: the real opens (nt_to_unix_file_name -> "...").
  grep -a ':file:' "$LOG" | grep -aoE '> "/[^"]*"' | sed -E 's/^> "/U\tFILE\t/; s/"$//' >>"$RAW"
  # (B) Wine drive-root probes (find_drive_rootA "<unixpath>" -> ...).
  grep -a ':file:find_drive_rootA' "$LOG" \
    | sed -E 's/.*find_drive_rootA "([^"]*)".*/U\tFILE\t\1/' >>"$RAW"
  # (C) NT file paths (incl. unresolved probes for files that do not exist).
  grep -a ':file:' "$LOG" | grep -aoE 'L"[^"]*:[^"]*"' | sed -E 's/^L"/N\tFILE\t/; s/"$//' >>"$RAW"
  # (D) registry keys, hive-rooted (\Registry\Hive\...).
  grep -a ':reg:' "$LOG" | grep -aoE 'L"[^"]*Registry[^"]*"' | sed -E 's/^L"//; s/"$//' \
    | sed -E 's#\\+#/#g; s#/+#/#g; s#^/Registry/##; s#^Registry/##' \
    | sed -E 's/^/R\tREG\t/' >>"$RAW"
}

extract_syscall() {   # strace or bpftrace: all quoted "/..." path tokens
  grep -aoE '"/[^"]*"' "$LOG" | sed -E 's/^"/U\tFILE\t/; s/"$//' >>"$RAW"
}

case "$MODE" in
  winedebug) extract_winedebug ;;
  strace|bpftrace) extract_syscall ;;
esac

# --- Classify -------------------------------------------------------------------
# buckets: base (immutable Wine/client install), state (in the prefix-state.sh
# set), host-env (clock/RNG/locale/timezone/fonts/DNS/run-noise, neutralized
# elsewhere), unexpected (investigate).

# Does a prefix-relative path fall in the declared state set? Reuses STATE_GLOBS.
is_state_relpath() {
  local rel="$1" g
  for g in "${STATE_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$rel" == $g || "$rel" == $g/* ]] && return 0
  done
  return 1
}

classify_host() {
  case "$1" in
    /opt/wine*|/usr/lib/wine*|/usr/lib/*/wine*|/usr/share/wine*|/home/wine/.cache/wine*|/home/wine/.cache) echo base ;;
    # Wine's XDG desktop integration (menu/icon/mime registration it writes on
    # startup) -- install-class output, not state the client reads.
    /home/wine/.local/share/applications*|/home/wine/.local/share/icons*|/home/wine/.local/share/mime*|/home/wine/.local/share/desktop-directories*|/home/wine/.config/menus*) echo base ;;
    /home/wine/.local|/home/wine/.local/share|/home/wine/.config) echo base ;;
    /usr/share/fonts*|/etc/fonts*|/usr/local/share/fonts*|/home/wine/.fonts*|/home/wine/.local/share/fonts*) echo host-env ;;
    /usr/lib/locale*|/usr/share/locale*|/usr/share/i18n*|/usr/share/X11/locale*) echo host-env ;;
    /etc/localtime|/usr/share/zoneinfo*) echo host-env ;;
    /dev/urandom|/dev/random|/dev/null|/dev/zero|/dev/full|/dev/fd*|/dev/tty*|/dev/dri*) echo host-env ;;
    /etc/resolv.conf|/etc/hosts|/etc/host.conf|/etc/nsswitch.conf|/etc/gai.conf|/etc/protocols|/etc/services|/etc/networks) echo host-env ;;
    /proc|/proc/*|/sys|/sys/*) echo host-env ;;
    /usr/share/mime*|/usr/share/icons*|/usr/share/themes*|/usr/share/glib*|/etc/mime.types) echo host-env ;;
    /tmp|/tmp/*) echo host-env ;;
    # Wine drive-root enumeration probes (find_drive_rootA on container dirs).
    /|/home|/home/wine|/opt|/usr|/usr/lib|/usr/share|/usr/local|/usr/bin|/bin|/lib|/lib*|/etc|/var|/run|/dev|/sbin) echo host-env ;;
    *) echo unexpected ;;
  esac
}

classify_file() {
  local p="$1"
  # Wine reaches the prefix through BOTH the C: and the Z: (host-root) drive, so a
  # prefix path can arrive as an absolute host path; fold it back to relative.
  case "$p" in
    "$WINEPREFIX"/*) p="${p#"$WINEPREFIX"/}" ;;
    "$WINEPREFIX")   p="." ;;
    /*) classify_host "$p"; return ;;
  esac
  if is_state_relpath "$p"; then echo state; return; fi
  case "$p" in
    # Ancestor dirs the client stats on the way to its AppData/ProgramData state
    # trees -- traversal to reach the state set, not reads outside it.
    drive_c/users/*/AppData|drive_c/users/*/AppData/Local|drive_c/users/*/AppData/Roaming|drive_c/users/*/AppData/LocalLow|drive_c/ProgramData) echo state ;;
    drive_c/windows|drive_c/windows/*) echo base ;;
    "drive_c/Program Files"|"drive_c/Program Files"/*|"drive_c/Program Files (x86)"/*) echo base ;;
    drive_c/ProgramData|drive_c/ProgramData/*) echo base ;;
    # user-profile run noise, excluded from the state set by design (Temp).
    drive_c/users/*/Temp|drive_c/users/*/Temp/*|drive_c/users/*/AppData/Local/Temp|drive_c/users/*/AppData/Local/Temp/*) echo host-env ;;
    # top-level prefix bookkeeping files (.update-timestamp, .windows-* etc.).
    .|.update-timestamp|.windows-*) echo base ;;
    # anything else, incl. non-Kakao reads under a user profile, is surfaced.
    *) echo unexpected ;;
  esac
}

classify_reg() {
  # The entire *persisted* Wine registry is system.reg (Machine), user.reg (the
  # per-user hive) and userdef.reg (.Default) -- all three are in STATE_GLOBS, so
  # any read of a persisted hive is covered by the state set. DynData and other
  # volatile hives are Wine-synthesized and not persisted (determinism-class).
  case "$1" in
    Machine|Machine/*|User|User/*) echo state ;;
    DynData|DynData/*) echo host-env ;;
    Registry|""|.) echo host-env ;;   # bare registry root handle
    *) echo unexpected ;;
  esac
}

# Aggregate unique tokens with counts, normalize per form, classify, tally. The
# loop runs over the de-duplicated token set only, so the per-path shell work is
# cheap even though the raw log is huge.
declare -A BUCKET_PATHS BUCKET_HITS SEEN
UNEXPECTED_FILE="$OUT/unexpected.txt"; : >"$UNEXPECTED_FILE"

while IFS=$'\t' read -r cnt form chan token; do
  [ -n "$token" ] || continue
  case "$form" in
    U) path="$(norm_unix "$token")" ;;
    N) path="$(norm_nt "$token")" ;;
    R) path="$token" ;;
    *) continue ;;
  esac
  [ -n "$path" ] || continue                      # norm dropped a non-path token
  path="${path%/}"; [ -n "$path" ] || path="/"    # drop trailing slash (not root)
  if [ "$chan" = REG ]; then b="$(classify_reg "$path")"; label="reg:$path"
  else b="$(classify_file "$path")"; label="$path"; fi
  # Count each distinct logical path once per bucket (forms can alias).
  key="$b|$label"
  if [ -z "${SEEN[$key]:-}" ]; then
    SEEN[$key]=1
    BUCKET_PATHS[$b]=$(( ${BUCKET_PATHS[$b]:-0} + 1 ))
    [ "$b" = unexpected ] && printf '%8d  %s\n' "$cnt" "$label" >>"$UNEXPECTED_FILE"
  fi
  BUCKET_HITS[$b]=$(( ${BUCKET_HITS[$b]:-0} + cnt ))
done < <(sort "$RAW" | uniq -c | sed -E 's/^ *([0-9]+) /\1\t/')

# --- Report ---------------------------------------------------------------------
total_paths=0; for b in base state host-env unexpected; do total_paths=$(( total_paths + ${BUCKET_PATHS[$b]:-0} )); done
unexp=${BUCKET_PATHS[unexpected]:-0}

echo
echo "================ state-set runtime validation ================"
echo "mode:    $MODE"
echo "client:  $EXE"
echo "hold:    ${SECONDS_HOLD}s   (client NOT logged in; DESIGN §11)"
echo "raw log: $LOG$( [ "$KEEP" -eq 1 ] || echo '  (deleted; pass --keep to retain)')"
echo "state set (prefix-state.sh STATE_GLOBS):"
for g in "${STATE_GLOBS[@]}"; do echo "    $g"; done
echo "--------------------------------------------------------------"
printf '%-12s %14s %14s\n' "bucket" "distinct paths" "accesses"
for b in base state host-env unexpected; do
  printf '%-12s %14s %14s\n' "$b" "${BUCKET_PATHS[$b]:-0}" "${BUCKET_HITS[$b]:-0}"
done
printf '%-12s %14s\n' "TOTAL" "$total_paths"
echo "--------------------------------------------------------------"
if [ "$unexp" -eq 0 ]; then
  echo "RESULT: no unexpected state-/identity-/determinism-bearing access."
  echo "        Every read fell into base, the declared state set, or host-env."
else
  echo "RESULT: $unexp unexpected distinct path(s) to investigate:"
  echo "        (host-folder probes pre-login, e.g. Desktop/Downloads, are"
  echo "         usually benign empty known-folder enumeration -- confirm each.)"
  echo
  printf '%8s  %s\n' "hits" "path"
  sort -k2 "$UNEXPECTED_FILE"
fi
echo "=============================================================="

if [ "$STRICT" -eq 1 ] && [ "$unexp" -gt 0 ]; then exit 3; fi
exit 0
