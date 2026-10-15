#!/usr/bin/env bash
# Spike check (DESIGN §13.1): prove the official client process starts under Wine
# headlessly and stays up. Does NOT log in (no account; see DESIGN §11 safety).
set -euo pipefail

HOLD="${LAUNCH_HOLD_SECONDS:-20}"
: "${WINEPREFIX:?WINEPREFIX must be set}"

EXE="$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)"
if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
  EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }

echo ">> launching: $EXE (hold ${HOLD}s)"
wine "$EXE" >/tmp/kakao.log 2>&1 &
sleep "$HOLD"

if pgrep -fi 'KakaoTalk.exe' >/dev/null 2>&1; then
  echo "PASS: KakaoTalk is running under Wine after ${HOLD}s"
  echo "----- last wine log lines -----"
  tail -n 20 /tmp/kakao.log 2>/dev/null || true
  wineserver -k >/dev/null 2>&1 || true
  exit 0
fi

echo "FAIL: KakaoTalk process not running after ${HOLD}s" >&2
echo "----- wine log -----" >&2
cat /tmp/kakao.log >&2 2>/dev/null || true
wineserver -k >/dev/null 2>&1 || true
exit 1
