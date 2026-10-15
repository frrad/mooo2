#!/usr/bin/env bash
# Build-time: silently install the official client into the Wine prefix.
# Runs headless under Xvfb. Fails loudly if KakaoTalk.exe is not produced.
set -euo pipefail

INSTALLER="${1:?usage: box-install.sh <installer.exe>}"
: "${WINEPREFIX:?WINEPREFIX must be set}"

start_xvfb() {
  Xvfb :0 -screen 0 1280x1024x24 >/tmp/xvfb-install.log 2>&1 &
  export DISPLAY=:0
  local i
  for i in $(seq 1 40); do
    xdpyinfo -display :0 >/dev/null 2>&1 && return 0
    sleep 0.3
  done
  echo "!! Xvfb did not come up" >&2
  cat /tmp/xvfb-install.log >&2 || true
  return 1
}

start_xvfb
XVFB_PID=$!

# Tear the build-time display down on exit so its /tmp/.X0-lock and socket are
# not baked into the image layer: at runtime a stale lock whose PID happens to
# be alive makes Xvfb refuse to start, and the client exits with no display.
cleanup_xvfb() {
  kill "$XVFB_PID" 2>/dev/null || true
  wait "$XVFB_PID" 2>/dev/null || true
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0
}
trap cleanup_xvfb EXIT

echo ">> initializing Wine prefix (WINEARCH=${WINEARCH:-unset})"
WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init
wineserver -w || true

echo ">> running installer silently (NSIS /S): $INSTALLER"
# NSIS self-extractors honor /S for a silent install. The installer may spawn
# the client when done, so we give it time, then tear the session down.
wine "$INSTALLER" /S || true
sleep 15
wineserver -k || true
sleep 2

FOUND="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
if [ -z "$FOUND" ]; then
  echo "!! KakaoTalk.exe not found after install" >&2
  echo "   drive_c top-level:" >&2
  ls -la "$WINEPREFIX/drive_c" >&2 2>/dev/null || true
  for d in "$WINEPREFIX/drive_c/Program Files" "$WINEPREFIX/drive_c/Program Files (x86)"; do
    echo "   $d:" >&2; ls -la "$d" >&2 2>/dev/null || true
  done
  exit 1
fi

echo ">> installed: $FOUND"
printf '%s\n' "$FOUND" > /home/wine/.kakao_exe_path
echo ">> box-install complete"
