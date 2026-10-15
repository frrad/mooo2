#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md): snapshot / restore / diff ONLY the
# mutable state of the Wine prefix, not the whole 1.5 GB world.
#
# The prefix is ~1.5 GB, but ~1.53 GB of that is immutable base (Wine's own
# C:\windows, ~1.4 GB, and the installed client, ~135 MB) that is identical every
# run and already lives in the image's read-only layers. The only per-run /
# per-account state the client's output depends on is the registry plus the Kakao
# app-data tree — single-digit MB. This tool operates on exactly that set, so the
# snapshot/restore/diff loop stays fast enough for CI.
#
# For re-baselining the whole box (new client release, DESIGN §9), use the
# full-prefix prefix-snapshot.sh / prefix-restore.sh / prefix-diff.sh instead.
#
# Usage:
#   prefix-state.sh snapshot <out.tar>
#   prefix-state.sh restore  <state.tar>
#   prefix-state.sh diff     <baseline.tar> [--hash]
set -euo pipefail

: "${WINEPREFIX:?WINEPREFIX must be set}"
shopt -s nullglob

# --- The state set --------------------------------------------------------------
# Everything the client's output depends on that is NOT immutable base, relative
# to $WINEPREFIX. The registry files carry the synthesized device identity
# (machine GUID, volume serials, computer name) as well as config. The AppData
# Kakao trees carry the local DB/config/caches. Temp is deliberately excluded as
# run noise. Keep this list as the single source of truth.
STATE_GLOBS=(
  system.reg
  user.reg
  userdef.reg
  "drive_c/users/*/AppData/Local/Kakao"
  "drive_c/users/*/AppData/Roaming/Kakao"
  "drive_c/users/*/AppData/LocalLow/Kakao"
  "drive_c/ProgramData/Kakao"
)

# Existing state paths (relative to the prefix), one per line.
state_paths() {
  local g p
  ( cd "$WINEPREFIX" && for g in "${STATE_GLOBS[@]}"; do
      for p in $g; do [ -e "$p" ] && printf '%s\n' "$p"; done
    done )
}

# Build "<key>\t<relpath>" for every file under the given relative roots, rooted
# at $1. key = size (default) or sha256 when MODE=--hash.
manifest() {
  local root="$1"; shift
  local r
  ( cd "$root" && for r in "$@"; do
      [ -e "$r" ] || continue
      find "$r" -type f -print0 | while IFS= read -r -d '' f; do
        if [ "${MODE:-}" = "--hash" ]; then
          printf '%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
        else
          printf '%s\t%s\n' "$(stat -c '%s' "$f")" "$f"
        fi
      done
    done )
}

cmd_snapshot() {
  local out="${1:?usage: prefix-state.sh snapshot <out.tar>}"
  mapfile -t paths < <(state_paths)
  [ "${#paths[@]}" -gt 0 ] || echo "WARN: no state paths present yet (pre-login prefix?)" >&2
  # Archive paths are stored relative to the prefix root (e.g. 'system.reg',
  # 'drive_c/users/wine/AppData/Local/Kakao/...').
  tar -C "$WINEPREFIX" \
      --sort=name --numeric-owner --owner=0 --group=0 --mtime='@0' \
      -cf "$out" -- "${paths[@]}"
  local bytes files
  bytes="$(stat -c '%s' "$out" 2>/dev/null || echo '?')"
  files="$(tar -tf "$out" | wc -l)"
  echo "state snapshot: $out  (${bytes} bytes, ${files} entries, ${#paths[@]} roots)"
}

cmd_restore() {
  local snap="${1:?usage: prefix-state.sh restore <state.tar>}"
  [ -f "$snap" ] || { echo "FAIL: snapshot '$snap' not found" >&2; exit 1; }
  case "$WINEPREFIX" in
    ""|"/"|"/home"|"/root"|"/home/wine") echo "FAIL: refusing to operate on '$WINEPREFIX'" >&2; exit 1 ;;
  esac
  # Release handles, then clear the current state set and extract the baseline
  # over the prefix. The immutable base is never touched.
  wineserver -k >/dev/null 2>&1 || true
  local p
  while IFS= read -r p; do rm -rf "${WINEPREFIX:?}/$p"; done < <(state_paths)
  tar -C "$WINEPREFIX" -xf "$snap"
  echo "state restored: $WINEPREFIX  <= $snap"
}

cmd_diff() {
  local base_tar="${1:?usage: prefix-state.sh diff <baseline.tar> [--hash]}"
  MODE="${2:-}"
  [ -f "$base_tar" ] || { echo "FAIL: baseline '$base_tar' not found" >&2; exit 1; }
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/base"
  tar -C "$tmp/base" -xf "$base_tar"

  # Baseline roots = whatever the archive holds; current roots = live state set.
  mapfile -t base_roots < <( cd "$tmp/base" && for g in "${STATE_GLOBS[@]}"; do for p in $g; do [ -e "$p" ] && printf '%s\n' "$p"; done; done )
  mapfile -t cur_roots  < <(state_paths)

  manifest "$tmp/base" "${base_roots[@]}" > "$tmp/base.man"
  manifest "$WINEPREFIX" "${cur_roots[@]}" > "$tmp/cur.man"

  awk -F'\t' -v mode="${MODE:-size}" -v base="$base_tar" '
    NR==FNR { bkey[$2]=$1; bhas[$2]=1; next }
    { chas[$2]=1
      if (!($2 in bkey))       { print "+ " $2; a++ }
      else if (bkey[$2] != $1) { print "~ " $2; c++ } }
    END {
      for (p in bkey) if (!(p in chas)) { print "- " p; r++ }
      print "---"
      printf "added=%d removed=%d changed=%d  (mode=%s, baseline=%s)\n", a+0, r+0, c+0, mode, base
    }' "$tmp/base.man" "$tmp/cur.man"
}

SUB="${1:?usage: prefix-state.sh snapshot|restore|diff ...}"; shift
case "$SUB" in
  snapshot) cmd_snapshot "$@" ;;
  restore)  cmd_restore  "$@" ;;
  diff)     cmd_diff     "$@" ;;
  *) echo "FAIL: unknown subcommand '$SUB'" >&2; exit 1 ;;
esac
