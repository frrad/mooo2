#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md, "Clock" and "RNG"): run a command
# (normally `wine ...`) with the clock and the CSPRNG seized, so both inputs are
# chosen by us, recorded, and replayable (DESIGN §5.1, §9).
#
#   clock  libfaketime (LD_PRELOAD) pins the wall clock to a start instant and lets
#          it advance in real time, as one clock for every process in the tree. It
#          also covers the monotonic clock that Wine's QueryPerformanceCounter /
#          GetTickCount read on the host.
#   RNG    rng-seize.so (LD_PRELOAD) replaces the host getrandom() under Wine's
#          ntdll, which every Windows CSPRNG API reaches. With a seed, every byte is
#          derived from it; the bytes served are logged per process.
# Both live below the Windows modules, so the client binary is never touched.
#
# Usage:
#   seize.sh [--time SPEC] [--seed N] [--log DIR] [--capture FILE] -- CMD [ARG]...
#   seize.sh --from FILE [--log DIR] -- CMD [ARG]...       # replay a capture
#
#   --time SPEC     start instant, e.g. "@2025-01-01 00:00:00" (default: now,
#                   rounded to the second, so a live record still gets pinned).
#                   The clock reads it when seize.sh runs. Any other libfaketime
#                   spec is passed through unchanged.
#   --seed N        64-bit RNG seed, hex or decimal (default: fresh random)
#   --log DIR       write <exe>.<pid>.rng (bytes served per process) under DIR
#   --capture FILE  write the chosen inputs (time + seed) as an env file
#   --from FILE     load the inputs from a capture file (replay)
#
# Start from a stopped wineserver (wineserver -k), or processes it already runs
# keep their unseized clock and RNG. Only seed a box that logs in with a
# disposable account: the client's keys become predictable to us (DESIGN §11).
set -euo pipefail

LIBDIR="${MOOO_LIBDIR:-/usr/local/lib/mooo}"
FAKETIME_LIB="${FAKETIME_LIB:-/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1}"
RNG_LIB="$LIBDIR/rng-seize.so"

TIME_SPEC=""
SEED=""
LOG_DIR=""
CAPTURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --time)    TIME_SPEC="${2:?}"; shift 2 ;;
    --seed)    SEED="${2:?}"; shift 2 ;;
    --log)     LOG_DIR="${2:?}"; shift 2 ;;
    --capture) CAPTURE="${2:?}"; shift 2 ;;
    --from)    # shellcheck disable=SC1090
               . "${2:?}"; TIME_SPEC="$MOOO_SEIZE_TIME"; SEED="$MOOO_RNG_SEED"; shift 2 ;;
    --)        shift; break ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "FAIL: unknown arg '$1'" >&2; exit 1 ;;
  esac
done
[ $# -gt 0 ] || { echo "FAIL: no command given (seize.sh [opts] -- CMD ...)" >&2; exit 1; }
for f in "$FAKETIME_LIB" "$RNG_LIB"; do
  [ -f "$f" ] || { echo "FAIL: $f not found in image" >&2; exit 2; }
done

# One clock for the whole Wine process tree. libfaketime's "@start" mode starts
# each process's clock when that process loads the library, and shares the start
# only through a POSIX shm segment named in FAKETIME_SHARED. FAKETIME_DONT_RESET
# relies on that segment, and under Wine it does not reach every process.
# wineboot is spawned without FAKETIME_SHARED, so it opens its own segment, and
# services.exe, rpcss.exe and the rest inherit that second start instant. A
# process started after the segment's creator has exited opens a fresh segment
# and restarts at the pinned instant. So turn "@start" into a fixed offset from
# the real clock, computed once here. Every process then reads real + offset,
# with no shared state. libfaketime applies the offset to the monotonic clocks
# too, so QueryPerformanceCounter and GetTickCount64 start at the pinned epoch.
# Any other spec (frozen "YYYY-MM-DD hh:mm:ss", "+2d", ...) passes through as is.
faketime_spec() {
  case "$1" in
    @*)
      local pin now off sign=+
      pin="$(date -d "${1#@}" +%s%N)" || { echo "FAIL: cannot parse --time '$1'" >&2; exit 1; }
      now="$(date +%s%N)"
      off=$((pin - now))
      [ "$off" -lt 0 ] && { sign=-; off=$((-off)); }
      printf '%s%d.%09d\n' "$sign" $((off / 1000000000)) $((off % 1000000000))
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

[ -n "$TIME_SPEC" ] || TIME_SPEC="@$(date '+%Y-%m-%d %H:%M:%S')"
[ -n "$SEED" ] || SEED="0x$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')"

if [ -n "$CAPTURE" ]; then
  mkdir -p "$(dirname "$CAPTURE")"
  printf 'MOOO_SEIZE_TIME=%q\nMOOO_RNG_SEED=%q\n' "$TIME_SPEC" "$SEED" > "$CAPTURE"
fi
if [ -n "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR"
  export MOOO_RNG_LOG="$LOG_DIR"
fi

# 32-bit Wine helpers cannot load these 64-bit libraries; ld.so says so on
# stderr and runs them unseized. The x64 client and its x64 helpers are seized.
export LD_PRELOAD="$FAKETIME_LIB:$RNG_LIB${LD_PRELOAD:+:$LD_PRELOAD}"
FAKETIME="$(faketime_spec "$TIME_SPEC")"
export FAKETIME
export MOOO_RNG_SEED="$SEED"
exec "$@"
