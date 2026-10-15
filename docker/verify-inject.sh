#!/usr/bin/env bash
# Spike A (docs/inject-spike.md; docs/driving.md §5): prove an injected DLL is
# loaded into the boxed client's process under Wine, and that the client stays up
# with it loaded. Does NOT log in and needs no account — like verify-launch.sh it
# stops at "the process launches and stays up", only now with loadprobe.dll
# injected (DESIGN §11 safety).
#
# Mechanism (see docs/inject-spike.md for the honesty note):
#   - WINEDLLOVERRIDES forces our module to load *native* (our build), not Wine's
#     builtin stub for that name.
#   - AppInit_DLLs is the import-agnostic *load trigger*: user32 loads it into
#     processes at startup, so the probe does not depend on the client importing
#     any particular DLL. This isolates "did an injected DLL load" from "did a
#     specific seam get hooked" (that is the production hook's job, not Spike A's).
set -euo pipefail

HOLD="${LAUNCH_HOLD_SECONDS:-20}"
: "${WINEPREFIX:?WINEPREFIX must be set}"

PROBE_SRC="${LOADPROBE_DLL:-/opt/patches/loadprobe.dll}"
PROBE_DST_WIN='C:\windows\loadprobe.dll'
PROBE_DST_UNIX="$WINEPREFIX/drive_c/windows/loadprobe.dll"
MARKER_WIN='C:\loadprobe.log'
MARKER_UNIX="$WINEPREFIX/drive_c/loadprobe.log"

[ -f "$PROBE_SRC" ] || { echo "FAIL: probe DLL not found at $PROBE_SRC" >&2; exit 1; }

EXE="$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)"
if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
  EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }

echo ">> staging probe: $PROBE_SRC -> $PROBE_DST_UNIX"
cp -f "$PROBE_SRC" "$PROBE_DST_UNIX"
rm -f "$MARKER_UNIX"
export KAKAO_LOADPROBE_MARKER="$MARKER_WIN"

echo ">> enabling AppInit_DLLs load trigger (registry)"
APPINIT_KEY='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Windows'
wine reg add "$APPINIT_KEY" /v AppInit_DLLs          /t REG_SZ    /d "$PROBE_DST_WIN" /f >/dev/null 2>&1
wine reg add "$APPINIT_KEY" /v LoadAppInit_DLLs       /t REG_DWORD /d 1               /f >/dev/null 2>&1
wine reg add "$APPINIT_KEY" /v RequireSignedAppInit_DLLs /t REG_DWORD /d 0            /f >/dev/null 2>&1
wineserver -w || true

# Force our module native so Wine honors the injected build over any builtin of
# the same name. This is the WINEDLLOVERRIDES knob driving.md names.
export WINEDLLOVERRIDES="loadprobe=n,b${WINEDLLOVERRIDES:+;${WINEDLLOVERRIDES}}"

echo ">> launching: $EXE (hold ${HOLD}s, WINEDLLOVERRIDES=$WINEDLLOVERRIDES)"
wine "$EXE" >/tmp/kakao.log 2>&1 &
sleep "$HOLD"

ALIVE=0
pgrep -fi 'KakaoTalk.exe' >/dev/null 2>&1 && ALIVE=1

LOADED_INTO_CLIENT=0
if [ -f "$MARKER_UNIX" ] && grep -qi 'KakaoTalk.exe' "$MARKER_UNIX"; then
  LOADED_INTO_CLIENT=1
fi

wineserver -k >/dev/null 2>&1 || true

echo "----- marker ($MARKER_UNIX) -----"
cat "$MARKER_UNIX" 2>/dev/null || echo "(no marker written)"

if [ "$LOADED_INTO_CLIENT" -eq 1 ] && [ "$ALIVE" -eq 1 ]; then
  echo "PASS: loadprobe.dll loaded into KakaoTalk.exe and the client stayed up for ${HOLD}s"
  exit 0
fi

echo "FAIL: injection did not satisfy Spike A" >&2
[ "$LOADED_INTO_CLIENT" -eq 1 ] || echo "  - no load marker for KakaoTalk.exe (override/AppInit not honored, or client never reached DLL load)" >&2
[ "$ALIVE" -eq 1 ]              || echo "  - client not running after ${HOLD}s (injection destabilized startup, or anti-tamper tripped — see docs/driving.md §6)" >&2
echo "----- wine log -----" >&2
cat /tmp/kakao.log >&2 2>/dev/null || true
exit 1
