#!/usr/bin/env bash
# Clock + RNG seize check (docs/containment.md "Clock", "RNG"; DESIGN §9). Like
# verify-launch.sh it does NOT log in and needs no account. It proves:
#   1. capture and replay: seize-probe.exe (our own program) reads every Windows
#      clock and CSPRNG API. Run once with a pinned time and seed, captured to an
#      env file, then again from that capture: the wall clock reads the pinned date,
#      QueryPerformanceCounter and GetTickCount64 sit at the pinned epoch, and
#      every random API returns the same bytes. A third run with another seed must
#      differ, so the bytes really come from the seed.
#   2. the UNMODIFIED client launches and stays up seized, with both seize
#      libraries mapped into KakaoTalk.exe. Any entropy it draws is logged.
set -euo pipefail

HOLD="${LAUNCH_HOLD_SECONDS:-20}"
: "${WINEPREFIX:?WINEPREFIX must be set}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${MOOO_LIBDIR:-/usr/local/lib/mooo}"
PROBE="$LIBDIR/seize-probe.exe"
RUN="${SEIZE_RUN_DIR:-/tmp/seize}"
PIN_TIME="@2025-01-01 00:00:00"
PIN_DATE="2025-01-01"
APIS="bcrypt_genrandom rtlgenrandom cryptgenrandom processprng rand_s uuidcreate"

# KAKAO_EXE is set by prefix-layer.sh run (the client's path inside the layer).
EXE="${KAKAO_EXE:-$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)}"
if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
  EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not built into the image" >&2; exit 1; }

rm -rf "$RUN"; mkdir -p "$RUN"
FAILS=()

probe() {   # probe <name> <seize args...>
  local name="$1"; shift
  wineserver -k >/dev/null 2>&1 || true; wineserver -w 2>/dev/null || true
  "$HERE/seize.sh" --log "$RUN/$name.rng" "$@" -- wine "$PROBE" \
    >"$RUN/$name.txt" 2>"$RUN/$name.err" || true
  wineserver -k >/dev/null 2>&1 || true; wineserver -w 2>/dev/null || true
}
field() { tr -d '\r' < "$2" | awk -v k="$1" '$1==k{print $2}'; }

# --- 1. Probe: capture, replay, different seed ----------------------------------
probe record --time "$PIN_TIME" --seed 0x5eed --capture "$RUN/seize.env"
probe replay --from "$RUN/seize.env"
probe other  --time "$PIN_TIME" --seed 0x5eee

echo "----- seize-probe (record) -----"; cat "$RUN/record.txt"
echo "----- capture ($RUN/seize.env) -----"; cat "$RUN/seize.env"

for k in systime systime_precise localtime; do
  v="$(field "$k" "$RUN/record.txt")"
  [ "${v:0:10}" = "$PIN_DATE" ] || FAILS+=("clock: $k=$v, want $PIN_DATE")
done
# libfaketime also fakes the host monotonic clock, which Wine's
# QueryPerformanceCounter and GetTickCount64 read: under the "@" start spec it
# reports the pinned epoch, so both counters must sit within minutes of it. An
# unseized counter reads host uptime instead.
PIN_EPOCH="$(date -u -d "${PIN_TIME#@}" +%s)"
for k in qpc_seconds tick_seconds; do
  v="$(field "$k" "$RUN/record.txt")"
  if ! [[ "$v" =~ ^[0-9]+$ ]] || [ $((v - PIN_EPOCH)) -lt 0 ] || [ $((v - PIN_EPOCH)) -gt 600 ]; then
    FAILS+=("clock: $k=$v, want within 600s after $PIN_EPOCH")
  fi
done
SAME=0
for k in $APIS; do
  a="$(field "$k" "$RUN/record.txt")"; b="$(field "$k" "$RUN/replay.txt")"; c="$(field "$k" "$RUN/other.txt")"
  if [ -z "$a" ] || [ "$a" = unavailable ]; then
    FAILS+=("rng: $k unavailable"); continue
  fi
  [ "$a" = "$b" ] || FAILS+=("rng: $k differs on replay ($a vs $b)")
  [ "$a" != "$c" ] || FAILS+=("rng: $k ignores the seed")
  [ "$a" = "$b" ] && [ "$a" != "$c" ] && SAME=$((SAME + 1))
done

# --- 2. The unmodified client, seized -------------------------------------------
wineserver -k >/dev/null 2>&1 || true; wineserver -w 2>/dev/null || true
echo ">> launching seized: $EXE (hold ${HOLD}s)"
"$HERE/seize.sh" --from "$RUN/seize.env" --log "$RUN/client.rng" -- wine "$EXE" \
  >/tmp/kakao.log 2>&1 &
disown $!
sleep "$HOLD"

ALIVE=0; MAPPED=0
PID="$(pgrep -fi 'KakaoTalk.exe' | head -1 || true)"
if [ -n "$PID" ]; then
  ALIVE=1
  if grep -q 'libfaketime' "/proc/$PID/maps" 2>/dev/null \
     && grep -q 'rng-seize' "/proc/$PID/maps" 2>/dev/null; then
    MAPPED=1
  fi
fi
wineserver -k >/dev/null 2>&1 || true

[ "$ALIVE" -eq 1 ]  || FAILS+=("client not running after ${HOLD}s")
[ "$ALIVE" -eq 0 ] || [ "$MAPPED" -eq 1 ] || FAILS+=("seize libraries not mapped into KakaoTalk.exe")
CLIENT_BYTES=0
for f in "$RUN"/client.rng/kakaotalk.exe.*.rng; do
  [ -f "$f" ] && CLIENT_BYTES=$((CLIENT_BYTES + $(stat -c %s "$f")))
done
echo "----- entropy served per process (client run) -----"
for f in "$RUN"/client.rng/*.rng; do [ -f "$f" ] && echo "  $(basename "$f") $(stat -c %s "$f") bytes"; done

if [ "${#FAILS[@]}" -eq 0 ]; then
  echo "PASS: clock (wall, QPC, tick) pinned to $PIN_DATE and $SAME/6 CSPRNG APIs replay byte-identical from the capture; KakaoTalk stayed up ${HOLD}s seized (drew ${CLIENT_BYTES} seeded bytes)"
  exit 0
fi
echo "FAIL: clock/RNG seize check did not pass" >&2
for f in "${FAILS[@]}"; do echo "  - $f" >&2; done
echo "----- probe stderr -----" >&2; grep -v 'wrong ELF class' "$RUN/record.err" >&2 || true
[ "$ALIVE" -eq 1 ] || { echo "----- wine log -----" >&2; cat /tmp/kakao.log >&2 || true; }
exit 1
