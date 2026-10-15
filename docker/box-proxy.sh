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

mkdir -p "$OUT_DIR"

# Try each client-bundled DLL the exe statically imports, in name order, and keep
# the first one for which a proxy actually builds with at least one name-based
# forwarder. A candidate is skipped when it exports nothing by name (e.g. it is
# import-by-ordinal only, which name-based forwarders cannot satisfy) or when the
# proxy fails to link; see "Known limitation" in docs/inject-spike.md.
target=""
tried=0
while IFS= read -r f; do
  b="$(basename "$f")"
  lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$imports" | grep -Fqx "$lb" || continue
  tried=$((tried + 1))

  base="${b%.*}"
  origmod="${base}__orig"
  def="$OUT_DIR/${base}.def"

  echo ">> box-proxy: candidate '$b' (forwards -> ${origmod}.dll)"
  if ! "$GENDEF_FWD" "$APPDIR/$b" "$origmod" > "$def" 2>/dev/null; then
    echo ">> box-proxy: '$b': forwarder generation failed; trying next" >&2
    continue
  fi
  nfwd=$(($(wc -l < "$def") - 1))
  if [ "$nfwd" -lt 1 ]; then
    echo ">> box-proxy: '$b': zero named exports (ordinal-only?); trying next" >&2
    continue
  fi
  if ! "$GCC" -O2 -shared -o "$OUT_DIR/$b" "$PROBE_SRC" "$def" -luser32 2>/dev/null; then
    echo ">> box-proxy: '$b': proxy failed to link; trying next" >&2
    continue
  fi
  echo ">> forwarders generated: $nfwd exports"
  target="$b"
  break
done < <(find "$APPDIR" -maxdepth 1 -iname '*.dll' | sort)

if [ -z "$target" ]; then
  echo "box-proxy: no usable client-bundled static import ($tried candidate(s) tried)" >&2
  exit 1
fi

printf '%s\n' "$target" > /home/wine/.kakao_proxy_target

echo ">> box-proxy: built proxy $OUT_DIR/$target (recorded target: $target)"
