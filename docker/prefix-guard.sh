#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md, "Validating the state set" method 4):
# ENFORCE the declared state set, don't just observe it. This is the enforcing
# companion to the observing prefix-trace.sh.
#
# Two layers, both out-of-process (no ptrace, anti-tamper-safe), both needing a
# privileged / CAP_SYS_ADMIN container:
#
#   1. Structural read-only base. Bind-remount the immutable install
#      (BASE_PATHS in prefix-state.sh) READ-ONLY, so the client cannot
#      write outside its state (writes fail EROFS) and reads of unprovisioned base
#      paths fail ENOENT. The prefix itself is bind-mounted to itself first, which
#      also bounds the fanotify scope below to the prefix subtree.
#   2. Active fanotify guard (prefix-guard.py). Intercepts every open in the
#      writable region and SIGKILLs the client on any access outside the state set
#      / base / known-benign list -- a hard crash on an off-list read -- or logs it
#      under --log-only.
#
# The state set is the single source of truth from prefix-state.sh: this wrapper
# sources it and passes STATE_GLOBS to the guard; it is never redefined.
#
# Converge the allowlist with prefix-trace.sh BEFORE enabling --kill (the default):
# a too-tight list crashes the client on a legitimate read. The guard seeds the
# known pre-login residue so the unmodified client runs clean; add scenario-specific
# exceptions with --allow-extra.
#
# Usage (must be root; e.g. docker run --privileged -u 0 ... prefix-guard.sh):
#   prefix-guard.sh [--seconds N] [--log-only] [--no-readonly]
#                   [--exe PATH] [--allow-extra GLOB]...
set -euo pipefail

: "${WINEPREFIX:?WINEPREFIX must be set}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=prefix-state.sh
source "$HERE/prefix-state.sh"   # STATE_GLOBS, BASE_PATHS (single source of truth)

SECONDS_HOLD="${LAUNCH_HOLD_SECONDS:-20}"
LOG_ONLY=0
READONLY=1
EXE=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)     SECONDS_HOLD="${2:?}"; shift 2 ;;
    --log-only)    LOG_ONLY=1; shift ;;
    --no-readonly) READONLY=0; shift ;;
    --exe)         EXE="${2:?}"; shift 2 ;;
    --allow-extra) EXTRA+=("--allow-extra" "${2:?}"); shift 2 ;;
    -h|--help)     sed -n '1,33p' "$0"; exit 0 ;;
    *) echo "FAIL: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  echo "FAIL: prefix-guard.sh must run as root (fanotify + mount need CAP_SYS_ADMIN)." >&2
  echo "      Run the container privileged, e.g.:" >&2
  echo "        docker run --rm --privileged -u 0 <image> prefix-guard.sh" >&2
  echo "      (or --cap-add SYS_ADMIN with a mount-capable setup)." >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found in image." >&2; exit 2; }

# Locate the client (same discovery as verify-launch.sh).
if [ -z "$EXE" ]; then
  # KAKAO_EXE is set by prefix-layer.sh run (the client's path inside the layer).
  EXE="${KAKAO_EXE:-$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)}"
  if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
    EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
  fi
fi
[ -n "$EXE" ] && [ -f "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }

# --- Structural layer: bind the prefix to itself, remount base read-only --------
BOUND=0
RO_PATHS=()
teardown() {
  for p in "${RO_PATHS[@]}"; do umount "$p" 2>/dev/null || true; done
  [ "$BOUND" -eq 1 ] && umount "$WINEPREFIX" 2>/dev/null || true
}
trap teardown EXIT

if ! mountpoint -q "$WINEPREFIX"; then
  mount --bind "$WINEPREFIX" "$WINEPREFIX"     # bounds the fanotify mark's scope
fi
BOUND=1

if [ "$READONLY" -eq 1 ]; then
  for rel in "${BASE_PATHS[@]}"; do
    tgt="$WINEPREFIX/$rel"
    [ -d "$tgt" ] || continue
    mount --bind "$tgt" "$tgt"
    mount -o remount,ro,bind "$tgt"
    RO_PATHS+=("$tgt")
    echo ">> read-only base: $rel"
  done
fi

# --- Hand off to the fanotify guard --------------------------------------------
GLOB_ARGS=()
for g in "${STATE_GLOBS[@]}"; do GLOB_ARGS+=("--state-glob" "$g"); done
LOG_ARG=(); [ "$LOG_ONLY" -eq 1 ] && LOG_ARG=(--log-only)

# Run inline (not exec) so the mount teardown trap still fires afterwards.
rc=0
python3 "$HERE/prefix-guard.py" \
  --prefix "$WINEPREFIX" --exe "$EXE" --seconds "$SECONDS_HOLD" \
  "${LOG_ARG[@]}" "${GLOB_ARGS[@]}" "${EXTRA[@]}" || rc=$?
exit "$rc"
