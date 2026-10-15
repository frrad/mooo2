#!/usr/bin/env bash
# Build-time: construct the Spike A injection proxy (docs/inject-spike.md).
#
# Picks a DLL that ships WITH the client and is statically imported by the exe,
# then builds a proxy DLL (our DllMain probe + forwarders to a renamed copy of the
# original) named as that DLL. The proxy is left in a staging dir and the chosen
# name recorded; it is NOT swapped into the app dir here, so the image's client
# stays pristine for the unmodified-launch spike (verify-launch.sh). verify-inject.sh
# does the reversible swap at runtime.
#
# Why a bundled static import: it loads at process startup (so the probe fires
# during the hold window) and it is a real file we can rename and forward to —
# unlike a Wine builtin, which has no file to forward to. This is the vector the
# WeChat-box precedent uses (docs/alternatives.md); AppInit_DLLs is NOT honored by
# Wine, so it is not an option (see docs/inject-spike.md).
set -euo pipefail

: "${WINEPREFIX:?WINEPREFIX must be set}"
PROBE_SRC="${PROBE_SRC:-/opt/patches/loadprobe/loadprobe.c}"
GENDEF_FWD="${GENDEF_FWD:-/opt/patches/dllproxy/gen-forwarders.sh}"
OUT_DIR="${OUT_DIR:-/home/wine/proxy}"
OBJDUMP=x86_64-w64-mingw32-objdump
GCC=x86_64-w64-mingw32-gcc

EXE="$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)"
if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
  EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ] || { echo "box-proxy: KakaoTalk.exe not found" >&2; exit 1; }
APPDIR="$(dirname "$EXE")"

# DLL names the exe statically imports (lowercased, for matching).
imports="$("$OBJDUMP" -p "$EXE" | awk '/DLL Name:/{print tolower($3)}')"

# Pick the first client-bundled DLL that the exe statically imports.
target=""
while IFS= read -r f; do
  b="$(basename "$f")"
  lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
  if printf '%s\n' "$imports" | grep -qx "$lb"; then target="$b"; break; fi
done < <(find "$APPDIR" -maxdepth 1 -iname '*.dll' | sort)

[ -n "$target" ] || { echo "box-proxy: no client-bundled DLL is statically imported by the exe" >&2; exit 1; }

base="${target%.*}"
origmod="${base}__orig"
mkdir -p "$OUT_DIR"
def="$OUT_DIR/${base}.def"

echo ">> box-proxy: proxying bundled static import '$target' (forwards -> ${origmod}.dll)"
"$GENDEF_FWD" "$APPDIR/$target" "$origmod" > "$def"
echo ">> forwarders generated: $(($(wc -l < "$def") - 1)) exports"

"$GCC" -O2 -shared -o "$OUT_DIR/$target" "$PROBE_SRC" "$def" -luser32
printf '%s\n' "$target" > /home/wine/.kakao_proxy_target

echo ">> box-proxy: built proxy $OUT_DIR/$target (recorded target: $target)"
