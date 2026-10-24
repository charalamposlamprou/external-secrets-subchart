#!/usr/bin/env bash
# Fails when a values.yaml key is missing from README.md's "Values reference", so the hand-written
# docs can't silently drift from the chart. Checks top-level keys and the keys of the blocks
# users set directly (aws, defaults, parameterStore, secretsManager).
set -euo pipefail
cd "$(dirname "$0")/.."

reference="$(awk '/^## Values reference/{p=1; next} p && /^## /{exit} p' README.md)"
nested='^(aws|defaults|parameterStore|secretsManager)$'
advanced='^(externalSecrets|pushSecrets|serviceAccounts|secretStores|clusterSecretStores|clusterExternalSecrets)$'
missing=0

while IFS= read -r line; do
  [[ "$line" =~ ^([A-Za-z][A-Za-z0-9]*): ]] || continue
  top="${BASH_REMATCH[1]}"
  if [[ "$top" =~ $advanced ]]; then
    grep -q '`<advanced block>.enabled`' <<<"$reference" || { echo "missing: <advanced block> row (for $top)"; missing=1; }
  elif ! grep -qE "\`${top}(\`|\.)" <<<"$reference"; then
    echo "missing: ${top}"; missing=1
  fi
  current="$top"
done < values.yaml

current=""
while IFS= read -r line; do
  if [[ "$line" =~ ^([A-Za-z][A-Za-z0-9]*): ]]; then current="${BASH_REMATCH[1]}"; continue; fi
  [[ "$current" =~ $nested && "$line" =~ ^\ \ ([A-Za-z][A-Za-z0-9]*): ]] || continue
  key="${current}.${BASH_REMATCH[1]}"
  grep -qF "\`${key}" <<<"$reference" || { echo "missing: ${key}"; missing=1; }
done < values.yaml

if (( missing )); then
  echo "Document the keys above in README.md > Values reference."
  exit 1
fi
echo "ok   docs: every values.yaml key is in the README values reference"
