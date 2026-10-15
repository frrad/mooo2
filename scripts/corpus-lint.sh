#!/usr/bin/env bash
# Fails if the replay corpus contains values that look unscrubbed.
# See DESIGN.md §10.1 and §11.
#
# Usage: scripts/corpus-lint.sh <corpus-dir>
#
# A match is reported unless it also matches a regex in <corpus-dir>/.lint-allow
# (one extended regex per line, # comments allowed). Put the scrubber's
# placeholder forms and known-public values there. These patterns are a
# backstop, not a substitute for the scrubber.
set -euo pipefail

dir=${1:?usage: corpus-lint.sh <corpus-dir>}
allow="$dir/.lint-allow"

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
)

joined=$(IFS='|'; echo "${patterns[*]}")

# -o prints each match on its own line as file:line:match.
hits=$(grep -rnoIE --exclude=.lint-allow -e "$joined" "$dir" || true)

if [[ -n "$hits" && -f "$allow" ]]; then
  allow_re=$(grep -vE '^\s*(#|$)' "$allow" | paste -sd'|' || true)
  if [[ -n "$allow_re" ]]; then
    # Filter on the match itself (everything after file:line:).
    hits=$(awk -v re="^($allow_re)$" '{
      m = $0; sub(/^[^:]*:[0-9]+:/, "", m)
      if (m !~ re) print
    }' <<<"$hits")
  fi
fi

if [[ -n "$hits" ]]; then
  echo "Possible unscrubbed values in $dir:" >&2
  # Print only locations; the values themselves would land in public logs.
  cut -d: -f1,2 <<<"$hits" | sort -u >&2
  exit 1
fi
echo "corpus-lint: $dir clean"
