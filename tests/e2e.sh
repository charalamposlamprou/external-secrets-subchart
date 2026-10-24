#!/usr/bin/env bash
# End-to-end test against a real External Secrets Operator and a mock AWS (moto), in a
# throwaway cluster:
#   kind create cluster --name eso-e2e
#   tests/e2e.sh
# aws.auth: irsa: ESO authenticates exactly as in EKS: it requests a token for the chart's
# ServiceAccount, calls STS AssumeRoleWithWebIdentity with aws.roleArn, then reads SSM and
# Secrets Manager. Only the AWS endpoints are swapped for moto.
# aws.auth: podIdentity: the controller gets its own credentials from the standard AWS env vars
# (the AWS SDK's default chain, the same path EKS Pod Identity credentials take; kind can't run
# the real Pod Identity agent), then ESO assumes the app role with session tags.
# Both modes run side by side in one cluster. IAM policies aren't enforced by moto; the
# Terraform tests cover those.
set -euo pipefail
cd "$(dirname "$0")/.."

eso_version="${ESO_CHART_VERSION:-2.14.0}"
endpoint="http://moto.aws-mock.svc.cluster.local:5000"
ns=my-app
failed=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }

echo "--- mock AWS"
kubectl create namespace aws-mock --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f tests/e2e/moto.yaml >/dev/null
kubectl -n aws-mock rollout status deploy/moto --timeout=180s >/dev/null
kubectl -n aws-mock exec -i deploy/moto -- python - < tests/e2e/seed.py
kubectl -n aws-mock exec deploy/moto -- python -c '
import urllib.request
for op in ("stop-recording", "reset-recording", "start-recording"):
    urllib.request.urlopen(urllib.request.Request(f"http://localhost:5000/moto-api/recorder/{op}", method="POST"))' >/dev/null

echo "--- External Secrets Operator ${eso_version}"
helm upgrade --install external-secrets external-secrets \
  --repo https://charts.external-secrets.io --version "$eso_version" \
  -n external-secrets --create-namespace --wait --timeout 5m \
  --set "extraEnv[0].name=AWS_STS_ENDPOINT" --set "extraEnv[0].value=${endpoint}" \
  --set "extraEnv[1].name=AWS_SSM_ENDPOINT" --set "extraEnv[1].value=${endpoint}" \
  --set "extraEnv[2].name=AWS_SECRETSMANAGER_ENDPOINT" --set "extraEnv[2].value=${endpoint}" \
  --set "extraEnv[3].name=AWS_ACCESS_KEY_ID" --set "extraEnv[3].value=controller-identity" \
  --set "extraEnv[4].name=AWS_SECRET_ACCESS_KEY" --set "extraEnv[4].value=controller-identity" >/dev/null

echo "--- this chart"
# ESO's webhook can take a moment to accept requests after its pods are ready.
for _ in $(seq 1 30); do
  helm upgrade --install my-app . -n "$ns" --create-namespace -f tests/e2e/values.yaml >/dev/null 2>&1 && break
  sleep 5
done
helm status my-app -n "$ns" >/dev/null

if kubectl -n "$ns" wait --for=condition=Ready secretstore --all --timeout=120s >/dev/null; then
  pass "SecretStores Valid (IRSA token -> STS AssumeRoleWithWebIdentity)"
else
  fail "SecretStores not Valid"; kubectl -n "$ns" describe secretstore
fi
# On a re-run the Secrets may hold values from the last run; re-read everything now.
kubectl -n "$ns" annotate externalsecret --all force-sync="$(date +%s)" --overwrite >/dev/null
sleep 2
if kubectl -n "$ns" wait --for=condition=Ready externalsecret --all --timeout=120s >/dev/null; then
  pass "ExternalSecrets synced"
else
  fail "ExternalSecrets not synced"; kubectl -n "$ns" describe externalsecret
fi

value() { kubectl -n "$ns" get secret "$1" -o "go-template={{ index .data \"$2\" | base64decode }}" 2>/dev/null || true; }
expect() {  # <secret> <key> <expected value>
  local got; got="$(value "$1" "$2")"
  if [[ "$got" == "$3" ]]; then pass "$1/$2"; else fail "$1/$2: got '${got}', want '$3'"; fi
}
expect_keys() {  # <secret> <space-separated sorted keys>
  local got; got="$(kubectl -n "$ns" get secret "$1" -o go-template='{{ range $k, $_ := .data }}{{ $k }} {{ end }}' | xargs)"
  if [[ "$got" == "$2" ]]; then pass "$1 keys: $2"; else fail "$1 keys: got '${got}', want '$2'"; fi
}

for _ in $(seq 1 30); do [[ "$(value my-app-config LOG_LEVEL)" == debug ]] && break; sleep 2; done
expect my-app-config LOG_LEVEL debug
expect my-app-config API_URL https://api.example.com
expect_keys my-app-flags "FEATURE_A nested_FEATURE_B"
expect my-app-flags FEATURE_A on
expect my-app-flags nested_FEATURE_B off
expect my-app-dsn DB_PASS s3cret
expect my-app-dsn DATABASE_URL "postgres://app:s3cret@db.internal:5432/app"
expect_keys my-app-dsn "DATABASE_URL DB_HOST DB_PASS"
expect_keys my-app-env "ENV_A ENV_B"
expect my-app-env ENV_B 2
expect my-app-db DB_USER app
expect my-app-db DB_PASS pw
expect my-app-db API_TOKEN tok-123
expect my-app-registry .dockerconfigjson '{"auths": {"registry.example.com": {"auth": "dXNlcjpwYXNz"}}}'
type="$(kubectl -n "$ns" get secret my-app-registry -o jsonpath='{.type}')"
[[ "$type" == "kubernetes.io/dockerconfigjson" ]] && pass "my-app-registry type ${type}" || fail "my-app-registry type: got '${type}'"

echo "--- a changed parameter reaches the Secret"
kubectl -n aws-mock exec deploy/moto -- python -c '
import boto3
boto3.client("ssm", endpoint_url="http://localhost:5000", region_name="us-east-1",
             aws_access_key_id="test", aws_secret_access_key="test"
).put_parameter(Name="/my-app/log-level", Value="info", Type="String", Overwrite=True)'
kubectl -n "$ns" annotate externalsecret my-app-config force-sync="$(date +%s)" --overwrite >/dev/null
for _ in $(seq 1 30); do [[ "$(value my-app-config LOG_LEVEL)" == info ]] && break; sleep 2; done
expect my-app-config LOG_LEVEL info

echo "--- aws.auth: podIdentity, next to the IRSA apps"
pi_role="arn:aws:iam::123456789012:role/e2e-pi-app-secrets"
if helm upgrade --install pi-app . -n "$ns" -f tests/e2e/values.yaml \
     --set aws.auth=podIdentity --set "aws.roleArn=${pi_role}" \
     --set-json 'parameterStore.secrets={"pi-config":{"LOG_LEVEL":"/my-app/log-level"}}' \
     --set-json 'secretsManager.secrets={"pi-env":{"fromSecret":"my-app/env"}}' >/dev/null \
   && kubectl -n "$ns" wait --for=condition=Ready externalsecret/pi-config externalsecret/pi-env --timeout=120s >/dev/null; then
  # On a re-run pi-config may hold the value from before the parameter change above.
  kubectl -n "$ns" annotate externalsecret pi-config force-sync="$(date +%s)" --overwrite >/dev/null
  for _ in $(seq 1 30); do [[ "$(value pi-config LOG_LEVEL)" == info ]] && break; sleep 2; done
  expect pi-config LOG_LEVEL info
  expect_keys pi-env "ENV_A ENV_B"
else
  fail "pi-app didn't sync"; kubectl -n "$ns" describe externalsecret pi-config secretstore pi-app-parameter-store
fi
if kubectl -n "$ns" get serviceaccount pi-app-secrets >/dev/null 2>&1; then
  fail "podIdentity rendered a per-app ServiceAccount"
else
  pass "podIdentity renders no per-app ServiceAccount"
fi

echo "--- STS calls ESO made (moto recording)"
calls="$(kubectl -n aws-mock exec -i deploy/moto -- python - < tests/e2e/sts_calls.py)"
if grep -q "^AssumeRoleWithWebIdentity arn:aws:iam::123456789012:role/e2e-my-app-secrets" <<<"$calls"; then
  pass "irsa: AssumeRoleWithWebIdentity with the app's role"
else
  fail "irsa: no AssumeRoleWithWebIdentity for e2e-my-app-secrets"; echo "$calls" | sort -u
fi
if grep -q "^AssumeRole ${pi_role} .*esoNamespace=${ns}" <<<"$calls"; then
  pass "podIdentity: AssumeRole into the app role, tagged esoNamespace=${ns}"
else
  fail "podIdentity: no tagged AssumeRole for ${pi_role}"; echo "$calls" | sort -u
fi
if grep -q "^AssumeRoleWithWebIdentity ${pi_role}" <<<"$calls"; then
  fail "podIdentity app used IRSA"
else
  pass "podIdentity app never used IRSA"
fi

echo "--- a second app in the same namespace"
if helm upgrade --install other-app . -n "$ns" -f tests/e2e/values.yaml \
     --set-json 'parameterStore.secrets={"other-config":{"LOG_LEVEL":"/my-app/log-level"}}' \
     --set-json 'secretsManager.secrets={"other-env":{"fromSecret":"my-app/env"}}' >/dev/null; then
  kubectl -n "$ns" wait --for=condition=Ready externalsecret/other-config externalsecret/other-env --timeout=120s >/dev/null \
    && pass "second release installs and syncs alongside the first" || fail "second release didn't sync"
else
  fail "second release failed to install"
fi

exit "$failed"
