#!/usr/bin/env bash
# gen-forwarders.sh — emit a .def of name-based forwarder exports from a DLL to a
# renamed copy of itself, so a proxy DLL built with it satisfies every import the
# client resolves from the original while running our own DllMain first.
#
# Usage: gen-forwarders.sh <original.dll> <orig-module-basename> > proxy.def
#   <orig-module-basename> is the module the forwarders point at, WITHOUT ".dll"
#   (the loader appends it), e.g. "Vox3__orig".
#
# Export NAMES are read at build time with gendef (mingw-w64-tools) from whatever
# DLL is present — no client-specific symbol list is committed to the repo, so the
# proxy stays implementation-neutral and survives re-baselining (DESIGN §11, §12).
set -euo pipefail

DLL="${1:?usage: gen-forwarders.sh <original.dll> <orig-module-basename>}"
ORIGMOD="${2:?usage: gen-forwarders.sh <original.dll> <orig-module-basename>}"

echo "EXPORTS"
# gendef prints "LIBRARY ..." then "EXPORTS" then one decorated name per line
# (comment lines start with ';'). Each name becomes a forwarder to ORIGMOD.name.
gendef - "$DLL" \
  | awk '/^EXPORTS/{e=1; next} e && NF && $1 !~ /^;/ {print $1}' \
  | while IFS= read -r name; do
      printf '%s=%s.%s\n' "$name" "$ORIGMOD" "$name"
    done
