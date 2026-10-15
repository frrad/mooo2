#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md): list what the current Wine prefix has
# changed relative to a baseline snapshot. This is the observation half of the
# "Snapshot" strategy (DESIGN §5.1) — after driving the client, see which paths it
# persisted (local DB/config writes, registry keys, identity). Path+size level
# only; decoding the records themselves is the Tier 2 storage tap (future work).
#
# Usage: prefix-diff.sh <baseline.tar> [--hash]
#   default   compare by path + size (fast)
#   --hash    also compare file contents by sha256 (slower, catches same-size edits)
set -euo pipefail

BASE_TAR="${1:?usage: prefix-diff.sh <baseline.tar> [--hash]}"
MODE="${2:-}"
: "${WINEPREFIX:?WINEPREFIX must be set}"
[ -f "$BASE_TAR" ] || { echo "FAIL: baseline '$BASE_TAR' not found" >&2; exit 1; }

PREFIX_PARENT="$(dirname "$WINEPREFIX")"
PREFIX_BASE="$(basename "$WINEPREFIX")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

manifest() {
  # Emit "<key>\t<path>" for every file under PREFIX_BASE/, where key is size
  # (default) or sha256. Paths may contain spaces; they never contain tabs.
  local root="$1"
  ( cd "$root" && find "$PREFIX_BASE" -type f -print0 \
      | while IFS= read -r -d '' f; do
          if [ "$MODE" = "--hash" ]; then
            printf '%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
          else
            printf '%s\t%s\n' "$(stat -c '%s' "$f")" "$f"
          fi
        done )
}

mkdir -p "$TMP/base"
tar -C "$TMP/base" -xf "$BASE_TAR"

manifest "$TMP/base"       > "$TMP/base.man"
manifest "$PREFIX_PARENT"  > "$TMP/cur.man"

# Compare keyed on path (field 2, tab-delimited). awk handles spaces in paths.
awk -F'\t' -v mode="${MODE:-size}" -v base="$BASE_TAR" '
  NR==FNR { bkey[$2]=$1; bhas[$2]=1; next }
  {
    chas[$2]=1
    if (!($2 in bkey))       { print "+ " $2; a++ }
    else if (bkey[$2] != $1) { print "~ " $2; c++ }
  }
  END {
    for (p in bkey) if (!(p in chas)) { print "- " p; r++ }
    print "---"
    printf "added=%d removed=%d changed=%d  (mode=%s, baseline=%s)\n", a+0, r+0, c+0, mode, base
  }
' "$TMP/base.man" "$TMP/cur.man"
