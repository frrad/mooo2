#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md): capture the Wine prefix as a baseline
# snapshot. The prefix holds the client's local DB/config/caches (filesystem),
# the Wine registry (system.reg/user.reg/userdef.reg), and the synthesized device
# identity (machine GUID, volume serial), so one archive snapshots all three
# "Snapshot" channels of DESIGN §5.1 at once.
#
# Usage: prefix-snapshot.sh <out.tar>
# Writes a tar of $WINEPREFIX. Deterministic ordering so two snapshots of an
# unchanged prefix are byte-comparable. Does not touch the prefix.
set -euo pipefail

OUT="${1:?usage: prefix-snapshot.sh <out.tar>}"
: "${WINEPREFIX:?WINEPREFIX must be set}"
[ -d "$WINEPREFIX" ] || { echo "FAIL: WINEPREFIX '$WINEPREFIX' is not a directory" >&2; exit 1; }

PARENT="$(dirname "$WINEPREFIX")"
BASE="$(basename "$WINEPREFIX")"

# --sort=name + --numeric-owner: stable, host-independent ordering and ids.
# --mtime pins timestamps so an unchanged prefix hashes identically run to run.
tar -C "$PARENT" \
    --sort=name --numeric-owner --owner=0 --group=0 --mtime='@0' \
    -cf "$OUT" "$BASE"

BYTES="$(stat -c '%s' "$OUT" 2>/dev/null || echo '?')"
FILES="$(tar -tf "$OUT" | wc -l)"
echo "snapshot: $OUT  (${BYTES} bytes, ${FILES} entries)  <= $WINEPREFIX"
