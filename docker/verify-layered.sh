#!/usr/bin/env bash
# Layered-prefix check (docs/boxing.md "Layered prefix"). Like verify-launch.sh it
# does NOT log in and needs no account. Run it in a read-only container with the
# state layer on a tmpfs or volume (make layered-spike). It proves:
#   1. the layering invariants (prefix-layer.sh check): base trees linked, the whole
#      STATE_GLOBS set inside the state layer, the state layer not on overlay, and
#      C:\injector linked to the payload dir;
#   2. the base is immutable: writing into it, directly or through the prefix, fails;
#   3. the UNMODIFIED client launches from the layered prefix and stays up, and its
#      writes land in the state layer, where prefix-state.sh snapshots them.
set -euo pipefail

HOLD="${LAUNCH_HOLD_SECONDS:-20}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${KAKAO_BASE:-/home/wine/.wine}"
STATE="${KAKAO_STATE:-/var/lib/kakao/prefix}"
FAILS=()

"$HERE/prefix-layer.sh" assemble --fresh
"$HERE/prefix-layer.sh" check || FAILS+=("layering invariants")

# --- Base immutability ----------------------------------------------------------
for t in "$BASE/drive_c/windows/.layer-probe" "$STATE/drive_c/windows/.layer-probe" \
         "$STATE/drive_c/Program Files/.layer-probe"; do
  if ( : > "$t" ) 2>/dev/null; then
    rm -f "$t"
    FAILS+=("base is writable at $t (run the container with --read-only)")
  fi
done

# --- Launch from the layered prefix ---------------------------------------------
export WINEPREFIX="$STATE"
EXE="$STATE/$(sed "s|^$BASE/||" /home/wine/.kakao_exe_path)"
[ -f "$EXE" ] || FAILS+=("client not reachable through the layer at $EXE")
echo ">> launching: $EXE (hold ${HOLD}s)"
wine "$EXE" >/tmp/kakao.log 2>&1 &
disown $!
sleep "$HOLD"
ALIVE=0
pgrep -fi 'KakaoTalk.exe' >/dev/null 2>&1 && ALIVE=1
wineserver -k >/dev/null 2>&1 || true
wineserver -w 2>/dev/null || true     # registry hives are flushed on exit
[ "$ALIVE" -eq 1 ] || FAILS+=("client not running after ${HOLD}s")

WRITTEN="$(find "$STATE" -xdev -type f -newer "$STATE/.layer-base" | wc -l)"
[ "$WRITTEN" -gt 0 ] || FAILS+=("no writes reached the state layer")
SNAP="$(mktemp -d)/state.tar"
"$HERE/prefix-state.sh" snapshot "$SNAP" || FAILS+=("prefix-state.sh snapshot failed on the layer")
echo ">> state layer: $(du -sh "$STATE" | cut -f1), $WRITTEN files written this run"

if [ "${#FAILS[@]}" -eq 0 ]; then
  echo "PASS: KakaoTalk stayed up ${HOLD}s on a layered prefix: read-only base, state layer on $(stat -f -c %T "$STATE") ($WRITTEN files written), payload at C:\\injector"
  exit 0
fi
echo "FAIL: layered prefix check did not pass" >&2
for f in "${FAILS[@]}"; do echo "  - $f" >&2; done
[ "$ALIVE" -eq 1 ] || { echo "----- wine log -----" >&2; cat /tmp/kakao.log >&2 || true; }
exit 1
