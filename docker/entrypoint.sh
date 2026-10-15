#!/usr/bin/env bash
# Runtime entrypoint: ensure a headless display, wire the grey-box tap seam,
# then exec the container command (default: verify-launch.sh).
set -euo pipefail

DISP="${DISPLAY:-:0}"
if ! xdpyinfo -display "$DISP" >/dev/null 2>&1; then
  Xvfb "$DISP" -screen 0 1280x1024x24 >/tmp/xvfb-run.log 2>&1 &
  for i in $(seq 1 40); do
    xdpyinfo -display "$DISP" >/dev/null 2>&1 && break
    sleep 0.3
  done
fi
export DISPLAY="$DISP"

# --- Grey-box tap seam (DESIGN §5.2) -------------------------------------------
# A future tap is an injected DLL loaded via WINEDLLOVERRIDES. Empty by default,
# so the UNMODIFIED client runs (the §13.1 spike). To attach a hook later, set
# KAKAO_HOOK_OVERRIDES (e.g. "mytap=n,b") and drop the DLL into the prefix.
export WINEDLLOVERRIDES="${KAKAO_HOOK_OVERRIDES:-}"

exec "$@"
