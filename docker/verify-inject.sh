#!/usr/bin/env bash
# Spike A (docs/inject-spike.md; docs/driving.md §5): prove an injected DLL is
# loaded into the boxed client's process under Wine, and that the client stays up
# with it loaded. Like verify-launch.sh it does NOT log in and needs no account —
# it stops at "the process launches and stays up", only now with the probe DLL
# injected via a proxied client-bundled import (DESIGN §11 safety).
#
# The proxy (our DllMain probe + forwarders to a renamed copy of the original) is
# prebuilt at image-build time by box-proxy.sh. This script performs the reversible
# swap at runtime so the image's client stays pristine for verify-launch.sh:
#   original.dll  -> original__orig.dll   (kept; the proxy forwards here)
#   proxy         -> original.dll         (shadow; our DllMain runs first)
set -euo pipefail

HOLD="${LAUNCH_HOLD_SECONDS:-20}"
: "${WINEPREFIX:?WINEPREFIX must be set}"

EXE="$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)"
if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
  EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }
APPDIR="$(dirname "$EXE")"

TARGET="$(cat /home/wine/.kakao_proxy_target 2>/dev/null || true)"
[ -n "$TARGET" ] || { echo "FAIL: no proxy target recorded — box-proxy.sh did not run at build time" >&2; exit 1; }
PROXY="/home/wine/proxy/$TARGET"
[ -f "$PROXY" ] || { echo "FAIL: prebuilt proxy missing at $PROXY" >&2; exit 1; }

base="${TARGET%.*}"
ORIG="${base}__orig.dll"
MARKER="$WINEPREFIX/drive_c/loadprobe.log"

echo ">> installing proxy for '$TARGET' (original kept as '$ORIG')"
[ -f "$APPDIR/$ORIG" ] || cp "$APPDIR/$TARGET" "$APPDIR/$ORIG"
cp "$PROXY" "$APPDIR/$TARGET"
rm -f "$MARKER"

echo ">> launching: $EXE (hold ${HOLD}s)"
wine "$EXE" >/tmp/kakao.log 2>&1 &
sleep "$HOLD"

ALIVE=0
pgrep -fi 'KakaoTalk.exe' >/dev/null 2>&1 && ALIVE=1

LOADED=0
if [ -f "$MARKER" ] && grep -qi 'KakaoTalk.exe' "$MARKER"; then
  LOADED=1
fi

wineserver -k >/dev/null 2>&1 || true
# Leave the client pristine (useful for `make shell`; harmless under --rm).
cp "$APPDIR/$ORIG" "$APPDIR/$TARGET" 2>/dev/null || true

echo "----- marker ($MARKER) -----"
cat "$MARKER" 2>/dev/null || echo "(no marker written)"

if [ "$LOADED" -eq 1 ] && [ "$ALIVE" -eq 1 ]; then
  echo "PASS: probe loaded into KakaoTalk.exe via proxied $TARGET and the client stayed up for ${HOLD}s"
  exit 0
fi

echo "FAIL: injection did not satisfy Spike A" >&2
[ "$LOADED" -eq 1 ] || echo "  - no load marker for KakaoTalk.exe (proxy not loaded, or client never reached DLL load)" >&2
[ "$ALIVE" -eq 1 ]  || echo "  - client not running after ${HOLD}s (proxy broke startup, or anti-tamper tripped — see docs/driving.md §6)" >&2
echo "----- wine log -----" >&2
cat /tmp/kakao.log >&2 2>/dev/null || true
exit 1
