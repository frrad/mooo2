#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md): restore the Wine prefix to a baseline
# snapshot taken by prefix-snapshot.sh. This is the "restore to a known baseline
# before each run" step of DESIGN §5.1 — it resets the filesystem/DB, the Wine
# registry, and the synthesized device identity in one move.
#
# Usage: prefix-restore.sh <snapshot.tar>
# Replaces $WINEPREFIX with the archive contents. Stops wineserver first so no
# process is holding files. Extracts to a staging dir and swaps, so a failed
# extraction leaves the old prefix in place.
set -euo pipefail

SNAP="${1:?usage: prefix-restore.sh <snapshot.tar>}"
: "${WINEPREFIX:?WINEPREFIX must be set}"
[ -f "$SNAP" ] || { echo "FAIL: snapshot '$SNAP' not found" >&2; exit 1; }

# Guard against catastrophic targets before we rm -rf anything (tolerate a
# trailing slash in WINEPREFIX).
case "${WINEPREFIX%/}" in
  ""|"/"|"/home"|"/root"|"/home/wine") echo "FAIL: refusing to restore over '$WINEPREFIX'" >&2; exit 1 ;;
esac

PARENT="$(dirname "$WINEPREFIX")"
BASE="$(basename "$WINEPREFIX")"

# Release file handles the client/Wine may hold, or the swap can race.
wineserver -k >/dev/null 2>&1 || true

STAGING="$(mktemp -d "${PARENT}/.restore.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

tar -C "$STAGING" -xf "$SNAP"
[ -d "${STAGING}/${BASE}" ] || { echo "FAIL: archive did not contain '${BASE}/'" >&2; exit 1; }

rm -rf "$WINEPREFIX"
mv "${STAGING}/${BASE}" "$WINEPREFIX"

echo "restored: $WINEPREFIX  <= $SNAP"
