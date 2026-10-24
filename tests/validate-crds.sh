#!/usr/bin/env bash
# Server-side dry-run of every rendered fixture against a given ESO release's CRDs, so the
# API server validates the output against ESO's real schemas. Needs a throwaway cluster:
#   kind create cluster --name eso-crds
#   tests/validate-crds.sh v2.14.0
# Installs (server-side applies) that release's CRDs into the current kube context.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: $0 <eso-version, e.g. v2.14.0>}"
kubectl apply --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/external-secrets/external-secrets/${version}/deploy/crds/bundle.yaml" >/dev/null
kubectl wait --for condition=established --timeout=60s crd -l external-secrets.io/component=controller >/dev/null 2>&1 \
  || kubectl wait --for condition=established --timeout=60s crd --all >/dev/null
for ns in platform other; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done

failed=0
check() {  # <label> <rendered manifests>
  local out bad
  out="$(kubectl apply --dry-run=server -f - <<<"$2" 2>&1)" || true
  bad="$(grep -v '(server dry run)$' <<<"$out" || true)"
  if [[ -z "$bad" ]]; then
    echo "ok   ESO ${version}: $1 ($(grep -c '(server dry run)$' <<<"$out") objects)"
  else
    echo "FAIL ESO ${version}: $1"; sed 's/^/     /' <<<"$bad"; failed=1
  fi
}

for values in ci/full-values.yaml tests/cases/*.values.yaml; do
  # A fixture can declare the oldest ESO it needs: "# min-eso: v2.5.0" on its first line.
  min="$(sed -n '1s/^# min-eso: *\(v[0-9.]*\).*/\1/p' "$values")"
  if [[ -n "$min" && "$(printf '%s\n%s\n' "$min" "$version" | sort -V | head -n1)" != "$min" ]]; then
    echo "skip ESO ${version}: $values (needs ESO >= ${min})"; continue
  fi
  rendered="$(helm template ci . -f "$values")"
  grep -q '^kind:' <<<"$rendered" && check "$values" "$rendered"
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -R examples/parent-chart "$tmp/"
sed -i.bak 's#file://../..#file://'"$PWD"'#' "$tmp/parent-chart/Chart.yaml"
helm dependency update "$tmp/parent-chart" >/dev/null
check "examples/parent-chart" "$(helm template my-app "$tmp/parent-chart")"

exit "$failed"
