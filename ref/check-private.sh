#!/usr/bin/env bash
# Fails unless the kakao-ref package exists and is private. A package made
# public can never be made private again, so CI checks this before every push
# and after every release. See DESIGN.md §10.1 for the one-time setup that
# creates the package.
#
# Needs GH_TOKEN with read:packages. The owner is a user account; an org
# would use /orgs/<org>/... instead.
set -euo pipefail

owner=${GITHUB_REPOSITORY_OWNER:?}
if ! vis=$(gh api "/users/$owner/packages/container/kakao-ref" --jq .visibility); then
  echo "::error::cannot read kakao-ref package metadata (missing package or token?)"
  exit 1
fi
if [[ "$vis" != private ]]; then
  echo "::error::kakao-ref package visibility is '$vis', expected 'private'"
  exit 1
fi
echo "kakao-ref is private"
