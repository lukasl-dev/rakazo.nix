#!/usr/bin/env bash
set -euo pipefail

action=${1:?expected check or publish}
listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
{
  git diff --name-only --no-renames -z
  git diff --cached --name-only --no-renames -z
  git ls-files --others -z
} > "$listing"
changed=false
while IFS= read -r -d '' path; do
  if [[ "$path" != VERSION.json ]]; then
    printf 'Unexpected changed path: %q\n' "$path" >&2
    exit 1
  fi
  changed=true
done < "$listing"

if [[ "$action" == check ]]; then exit 0; fi
if [[ "$action" != publish ]]; then
  echo "Unknown action: $action" >&2
  exit 1
fi
if [[ "$changed" == false ]]; then
  echo 'No changes to publish'
  exit 0
fi

: "${BASE:?}" "${BRANCH:?}"
test "$(git rev-parse HEAD)" = "$BASE"
version=$(jq -er .version VERSION.json)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
git config user.name 'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'
git add -- VERSION.json
git commit -m "Update Rakazo to $version"
test "$(git rev-parse HEAD^)" = "$BASE"
test -z "$(git status --porcelain --untracked-files=all --ignored)"

remote=$(git ls-remote --exit-code origin "refs/heads/$BRANCH")
if [[ "$remote" != "$BASE"$'\t'"refs/heads/$BRANCH" ]]; then
  echo 'Default branch changed; rerun the update' >&2
  exit 1
fi
tag="refs/tags/v$version"
refs=("HEAD:refs/heads/$BRANCH")
if [[ -z $(git ls-remote --tags --refs origin "$tag") ]]; then
  git tag -a "v$version" -m "v$version"
  refs+=("$tag:$tag")
fi
# The direct-child check forbids history rewrites; the lease also detects a reset.
git push --atomic "--force-with-lease=refs/heads/$BRANCH:$BASE" origin "${refs[@]}"
