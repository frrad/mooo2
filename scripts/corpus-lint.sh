#!/usr/bin/env bash
# Denylist backstop for the replay corpus: fails if any file contains values
# that look unscrubbed. The scrubber is the real control; this catches its
# misses. See DESIGN.md §10.1 and §11.
#
# Usage: scripts/corpus-lint.sh <corpus-dir>
#
# - The corpus must be text only (decoded fields, no raw packet bytes or
#   archives). Any binary file fails the lint, since it cannot be scanned.
# - A match is reported unless the matched text fully matches a regex in
#   <corpus-dir>/.lint-allow (one GNU extended regex per line, # comments
#   allowed). Put the scrubber's placeholder forms there.
# - Only file:line is printed, never the value: CI logs are public.
set -euo pipefail

dir=${1:?usage: corpus-lint.sh <corpus-dir>}
dir=${dir%/}
allow="$dir/.lint-allow"

if [[ ! -d "$dir" ]]; then
  echo "corpus-lint: $dir is not a directory" >&2
  exit 1
fi

patterns=(
  # Korean mobile numbers, domestic and +82 forms.
  '(\+82[ -]?|\b0)1[016789][ -]?[0-9]{3,4}[ -]?[0-9]{4}\b'
  # Email addresses.
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  # Long hex strings: tokens, keys, device IDs.
  '\b[0-9A-Fa-f]{32,}\b'
  # Long base64 / base64url strings.
  '[A-Za-z0-9+/_-]{40,}={0,2}'
  # UUIDs (common device identifier shape).
  '\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b'
  # Numeric IDs in fields named *id / *Id / *ID (account, user, chat IDs).
  '"?[A-Za-z_]*([Ii]d|ID)"?[[:space:]]*[:=][[:space:]]*"?[0-9]{6,}'
)
joined=$(IFS='|'; echo "${patterns[*]}")

files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "$dir" -type f ! -path "$allow" -print0 | sort -z)

if (( ${#files[@]} == 0 )); then
  echo "corpus-lint: $dir has no files" >&2
  exit 1
fi

bad=()
hits=""
for f in "${files[@]}"; do
  # Non-empty files that grep treats as binary cannot be scanned.
  if [[ -s "$f" ]] && ! grep -qI '' "$f"; then
    bad+=("$f: binary file")
    continue
  fi
  rc=0
  out=$(grep -noE -e "$joined" "$f") || rc=$?
  if (( rc > 1 )); then
    echo "corpus-lint: cannot read $f" >&2
    exit 1
  fi
  [[ -n "$out" ]] && hits+=$(sed "s|^|$f:|" <<<"$out")$'\n'
done

if [[ -n "$hits" && -f "$allow" ]]; then
  allow_res=$(grep -vE '^[[:space:]]*(#|$)' "$allow" || true)
  if [[ -n "$allow_res" ]]; then
    kept=""
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      # Strip "file:line:" (file paths come from find under $dir).
      rest=${h#"$dir"/}; rest=${rest#*:}; m=${rest#*:}
      if ! grep -qxE -f <(printf '%s\n' "$allow_res") <<<"$m"; then
        kept+="$h"$'\n'
      fi
    done <<<"$hits"
    hits=$kept
  fi
fi

while IFS= read -r h; do
  [[ -z "$h" ]] && continue
  rest=${h#"$dir"/}; f=${rest%%:*}; rest=${rest#*:}; line=${rest%%:*}
  bad+=("$dir/$f:$line")
done <<<"$hits"

if (( ${#bad[@]} > 0 )); then
  echo "corpus-lint: possible unscrubbed values in $dir:" >&2
  printf '%s\n' "${bad[@]}" | sort -u >&2
  exit 1
fi
echo "corpus-lint: $dir clean (${#files[@]} files)"
