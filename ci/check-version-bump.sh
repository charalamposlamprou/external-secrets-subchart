#!/usr/bin/env bash
# Fails when the packaged chart changed relative to <base-ref> but Chart.yaml's
# version was not bumped past a version that is already released (tagged).
#   ci/check-version-bump.sh origin/main
set -euo pipefail
cd "$(dirname "$0")/.."

base_ref="${1:?usage: $0 <base-ref>}"
# Files that end up in the published package (see .helmignore).
chart_files=(Chart.yaml values.yaml values.schema.json templates README.md .helmignore)

version_of() { awk '/^version:/ {print $2; exit}'; }
base="$(git show "${base_ref}:Chart.yaml" | version_of)"
head="$(version_of < Chart.yaml)"

if git diff --quiet "$base_ref" HEAD -- "${chart_files[@]}"; then
  echo "Chart contents unchanged; no version bump needed."
  exit 0
fi

if [[ "$head" != "$base" ]]; then
  newest="$(printf '%s\n%s\n' "$base" "$head" | sort -V | tail -n1)"
  if [[ "$newest" != "$head" ]]; then
    echo "::error file=Chart.yaml::Chart version went backwards: ${base} -> ${head}"
    exit 1
  fi
  echo "Chart version bumped: ${base} -> ${head}"
  exit 0
fi

if git rev-parse -q --verify "refs/tags/v${base}" >/dev/null; then
  echo "::error file=Chart.yaml::Chart files changed but version ${base} is already released (tag v${base}). Bump 'version' in Chart.yaml."
  exit 1
fi
echo "Chart version ${base} is not released yet; changes ship with it."
