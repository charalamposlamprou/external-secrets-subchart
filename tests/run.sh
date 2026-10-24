#!/usr/bin/env bash
# Chart tests with no plugins: golden snapshots plus expected render failures.
#   tests/run.sh           run all tests
#   tests/run.sh --update  rewrite golden files from the current templates
set -euo pipefail
cd "$(dirname "$0")/.."

update=false
[[ "${1:-}" == "--update" ]] && update=true
failed=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }

# Golden snapshots: tests/cases/<name>.values.yaml -> tests/cases/<name>.golden.yaml
for values in ci/full-values.yaml tests/cases/*.values.yaml; do
  name="$(basename "$values" .values.yaml)"
  name="${name%.yaml}"
  golden="tests/cases/${name}.golden.yaml"
  rendered="$(helm template ci . -f "$values")"
  if $update; then
    printf '%s\n' "$rendered" > "$golden"
    echo "updated $golden"
  elif diff -u "$golden" <(printf '%s\n' "$rendered"); then
    pass "golden: $name"
  else
    fail "golden: $name (run tests/run.sh --update if the change is intended)"
  fi
done
$update && exit 0

# Expected failures: "<description>|<expected error substring>|<helm args...>"
while IFS='|' read -r desc want args; do
  [[ -z "$desc" || "$desc" == \#* ]] && continue
  # shellcheck disable=SC2086
  if out="$(helm template ci . $args 2>&1)"; then
    fail "rejects: $desc (rendered successfully)"
  elif grep -qF -- "$want" <<<"$out"; then
    pass "rejects: $desc"
  else
    fail "rejects: $desc (wrong error)"; echo "$out" | sed 's/^/     /'
  fi
done <<'CASES'
missing provider|must set provider|--set secretStores.s.namespace=x
provider in extraSpec|not in extraSpec|--set secretStores.s.provider.fake.data=null --set secretStores.s.extraSpec.provider.fake.data=null
ES without data|must set data and/or dataFrom|--set externalSecrets.e.namespace=x
ES without store name|defaults.secretStoreRef.name is empty|--set externalSecrets.e.dataFrom[0].extract.key=k
CES without spec|must set externalSecretSpec|--set clusterExternalSecrets.c.namespaces={a}
CES without store name|defaults.secretStoreRef.name is empty|--set clusterExternalSecrets.c.externalSecretSpec.dataFrom[0].extract.key=k
PushSecret without selector|must set selector and data|--set pushSecrets.p.data[0].match.secretKey=k
schema: enabled as string|enabled|--set-string enabled=false
schema: invalid store kind|kind|--set defaults.secretStoreRef.kind=Store
schema: typo in item key|datafrom|--set externalSecrets.e.datafrom[0].extract.key=k
schema: unknown top-level key|externalSecret|--set externalSecret.e.data=null
schema: non-string label value|commonLabels|--set commonLabels.tier=1
schema: item not a map|externalSecrets|--set externalSecrets.e=oops
CASES

exit "$failed"
