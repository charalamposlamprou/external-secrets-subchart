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
missing provider|must set provider|--set secretStores.enabled=true --set secretStores.items.s.namespace=x
provider in extraSpec|not in extraSpec|--set secretStores.enabled=true --set secretStores.items.s.provider.fake.data=null --set secretStores.items.s.extraSpec.provider.fake.data=null
ES without data|must set data and/or dataFrom|--set externalSecrets.enabled=true --set externalSecrets.items.e.namespace=x
ES without store name|defaults.secretStoreRef.name is empty|--set externalSecrets.enabled=true --set externalSecrets.items.e.dataFrom[0].extract.key=k
ES refs store of disabled feature|but secretStores.enabled is false|--set externalSecrets.enabled=true --set externalSecrets.items.e.dataFrom[0].extract.key=k --set defaults.secretStoreRef.name=s --set secretStores.items.s.provider.fake.data=null
CES without spec|must set externalSecretSpec|--set clusterExternalSecrets.enabled=true --set clusterExternalSecrets.items.c.namespaces={a}
CES ignores aws default store|defaults.secretStoreRef.name is empty|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set clusterExternalSecrets.enabled=true --set clusterExternalSecrets.items.c.externalSecretSpec.dataFrom[0].extract.key=k
PushSecret without selector|must set selector and data|--set pushSecrets.enabled=true --set pushSecrets.items.p.data[0].match.secretKey=k
aws without roleArn|aws.roleArn is empty|--set aws.enabled=true --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true
aws without region|aws.region is empty|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.secretsManager.enabled=true
aws without any service|neither aws.secretsManager.enabled nor aws.parameterStore.enabled|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1
aws defaultSource disabled|aws.defaultSource is "parameterStore"|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set aws.defaultSource=parameterStore
aws same store names|must differ|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set aws.parameterStore.enabled=true --set aws.secretsManager.storeName=x --set aws.parameterStore.storeName=x
aws store name collides|also defined in secretStores.items|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set secretStores.enabled=true --set secretStores.items.aws-secrets-manager.provider.fake.data=null
source without aws|but aws.enabled is false|--set externalSecrets.enabled=true --set externalSecrets.items.e.source=secretsManager --set externalSecrets.items.e.dataFrom[0].extract.key=k
source of disabled service|but aws.parameterStore.enabled is false|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set externalSecrets.enabled=true --set externalSecrets.items.e.source=parameterStore --set externalSecrets.items.e.dataFrom[0].extract.key=k
source and secretStoreRef|sets both source and secretStoreRef|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set externalSecrets.enabled=true --set externalSecrets.items.e.source=secretsManager --set externalSecrets.items.e.secretStoreRef.name=x --set externalSecrets.items.e.dataFrom[0].extract.key=k
PushSecret source and refs|sets both source and secretStoreRefs|--set aws.enabled=true --set aws.roleArn=arn:aws:iam::123456789012:role/r --set aws.region=eu-west-1 --set aws.secretsManager.enabled=true --set pushSecrets.enabled=true --set pushSecrets.items.p.source=secretsManager --set pushSecrets.items.p.secretStoreRefs[0].name=x --set pushSecrets.items.p.selector.secret.name=s --set pushSecrets.items.p.data[0].match.secretKey=k
AWS static access keys|uses static AWS access keys|--set secretStores.enabled=true --set secretStores.items.s.provider.aws.region=eu-west-1 --set secretStores.items.s.provider.aws.auth.secretRef.accessKeyIDSecretRef.name=k
AWS store, SA without roleArn|which has no roleArn|--set secretStores.enabled=true --set secretStores.items.s.provider.aws.region=eu-west-1 --set secretStores.items.s.provider.aws.auth.jwt.serviceAccountRef.name=sa --set serviceAccounts.enabled=true --set serviceAccounts.items.sa.labels.a=b
AWS store, disabled SA|which is disabled or removed|--set secretStores.enabled=true --set secretStores.items.s.provider.aws.region=eu-west-1 --set secretStores.items.s.provider.aws.auth.jwt.serviceAccountRef.name=sa --set serviceAccounts.enabled=true --set serviceAccounts.items.sa.enabled=false
AWS store, SA feature off|but serviceAccounts.enabled is false|--set secretStores.enabled=true --set secretStores.items.s.provider.aws.region=eu-west-1 --set secretStores.items.s.provider.aws.auth.jwt.serviceAccountRef.name=sa --set serviceAccounts.items.sa.roleArn=arn:aws:iam::123456789012:role/r
AWS store, SA in other namespace|must be in the same namespace|--set secretStores.enabled=true --set secretStores.items.s.provider.aws.region=eu-west-1 --set secretStores.items.s.provider.aws.auth.jwt.serviceAccountRef.name=sa --set serviceAccounts.enabled=true --set serviceAccounts.items.sa.roleArn=arn:aws:iam::123456789012:role/r --set serviceAccounts.items.sa.namespace=other
schema: old 0.2 layout|externalSecrets|--set externalSecrets.e.dataFrom[0].extract.key=k
schema: enabled as string|enabled|--set-string externalSecrets.enabled=true
schema: invalid store kind|kind|--set defaults.secretStoreRef.kind=Store
schema: typo in item key|datafrom|--set externalSecrets.enabled=true --set externalSecrets.items.e.datafrom[0].extract.key=k
schema: unknown source|source|--set externalSecrets.enabled=true --set externalSecrets.items.e.source=ssm
schema: unknown top-level key|externalSecret|--set externalSecret.enabled=true
schema: non-string label value|commonLabels|--set commonLabels.tier=1
schema: item not a map|externalSecrets|--set externalSecrets.enabled=true --set externalSecrets.items.e=oops
schema: malformed roleArn|roleArn|--set aws.roleArn=my-role
CASES

exit "$failed"
