#!/usr/bin/env bash
# Checks policies/eso-aws-session-tags.yaml against a real API server: applies the policy, then
# server-side dry-runs stores that must be denied or allowed (admission runs on dry-run too).
# Needs a throwaway cluster with ESO >= 2.5.0 CRDs, e.g. after tests/validate-crds.sh v2.14.0.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -f policies/eso-aws-session-tags.yaml >/dev/null
for ns in attacker platform; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
# The API server can take a while to start enforcing a new policy, especially on CRDs that
# were just installed. Wait for it, and stop if it never does (rather than testing nothing).
active=false
for _ in $(seq 1 60); do
  if out="$(kubectl apply --dry-run=server -f tests/policy/deny-forged-tags.yaml 2>&1)"; then sleep 2
  elif grep -q 'eso-aws-session-tags' <<<"$out"; then active=true; break
  else sleep 2; fi
done
if ! $active; then echo "FAIL policy never became active within 2 minutes"; exit 1; fi
failed=0

for f in tests/policy/deny-*.yaml; do
  if out="$(kubectl apply --dry-run=server -f "$f" 2>&1)"; then
    echo "FAIL policy: $f was allowed"; failed=1
  elif grep -q 'eso-aws-session-tags' <<<"$out"; then
    echo "ok   policy denies: $f"
  elif [[ "$f" == *custom-reserved-key* ]] && grep -q 'reserved keys' <<<"$out"; then
    echo "ok   ESO's CRD denies: $f"
  else
    echo "FAIL policy: $f rejected for another reason:"; sed 's/^/     /' <<<"$out"; failed=1
  fi
done
for f in tests/policy/allow-*.yaml; do
  if out="$(kubectl apply --dry-run=server -f "$f" 2>&1)"; then
    echo "ok   policy allows: $f"
  else
    echo "FAIL policy: $f denied:"; sed 's/^/     /' <<<"$out"; failed=1
  fi
done
# The chart's own output in both modes must pass.
for values in tests/cases/aws.values.yaml tests/cases/pod-identity.values.yaml tests/cases/serviceaccounts.values.yaml; do
  if out="$(helm template ci . -f "$values" | kubectl apply --dry-run=server -f - 2>&1)"; then
    echo "ok   policy allows chart output: $values"
  else
    echo "FAIL policy: chart output $values denied:"; grep -v '(server dry run)$' <<<"$out" | sed 's/^/     /'; failed=1
  fi
done
exit "$failed"
