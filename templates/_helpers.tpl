{{/*
Chart name. Hardcoded because .Chart.Name becomes the alias when used as an aliased dependency.
*/}}
{{- define "eso-sub.chartName" -}}external-secrets-subchart{{- end -}}

{{/*
Chart name and version label value.
*/}}
{{- define "eso-sub.chart" -}}
{{- printf "%s-%s" (include "eso-sub.chartName" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Resource name: optional (templated) prefix + item key, truncated to 63 chars.
Usage: include "eso-sub.name" (dict "root" $ "name" $name)
*/}}
{{- define "eso-sub.name" -}}
{{- $prefix := tpl (.root.Values.namePrefix | default "") .root -}}
{{- printf "%s%s" $prefix .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels. Usage: include "eso-sub.labels" (dict "root" $ "extra" $item.labels)
*/}}
{{- define "eso-sub.labels" -}}
{{- $base := dict
  "helm.sh/chart" (include "eso-sub.chart" .root)
  "app.kubernetes.io/name" (include "eso-sub.chartName" .root)
  "app.kubernetes.io/managed-by" .root.Release.Service
  "app.kubernetes.io/instance" .root.Release.Name
  "app.kubernetes.io/part-of" .root.Release.Name
  "app.kubernetes.io/component" "external-secrets" -}}
{{- toYaml (merge (deepCopy (.extra | default dict)) (deepCopy (.root.Values.commonLabels | default dict)) $base) -}}
{{- end -}}

{{/*
Metadata annotations block (renders nothing when empty).
Usage: include "eso-sub.annotations" (dict "root" $ "extra" $item.annotations)
*/}}
{{- define "eso-sub.annotations" -}}
{{- $a := merge (deepCopy (.extra | default dict)) (.root.Values.commonAnnotations | default dict) -}}
{{- if $a -}}
annotations:
  {{- toYaml $a | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Items of a feature block as YAML: `<feature>.items` when `<feature>.enabled`, else {}.
Usage: include "eso-sub.featureItems" (dict "root" $ "feature" "externalSecrets") | fromYaml
*/}}
{{- define "eso-sub.featureItems" -}}
{{- $f := index .root.Values .feature | default dict -}}
{{- if and $f.enabled $f.items -}}
{{- toYaml $f.items -}}
{{- else -}}
{}
{{- end -}}
{{- end -}}

{{/*
AWS block as YAML when aws.enabled, else empty:
  serviceAccountName: rendered IRSA account name (no namePrefix)
  stores: {secretsManager: <store key>, parameterStore: <store key>} for the enabled services
  defaultStore: store key used by items without secretStoreRef/source
Usage: include "eso-sub.aws" $ | fromYaml
*/}}
{{- define "eso-sub.aws" -}}
{{- $a := .Values.aws | default dict -}}
{{- if $a.enabled -}}
{{- if not $a.roleArn -}}
{{- fail "external-secrets-subchart: aws.enabled is true but aws.roleArn is empty" -}}
{{- end -}}
{{- if not $a.region -}}
{{- fail "external-secrets-subchart: aws.enabled is true but aws.region is empty" -}}
{{- end -}}
{{- $stores := dict -}}
{{- $sm := $a.secretsManager | default dict -}}
{{- $ps := $a.parameterStore | default dict -}}
{{- if $sm.enabled -}}{{- $_ := set $stores "secretsManager" ($sm.storeName | default "aws-secrets-manager") -}}{{- end -}}
{{- if $ps.enabled -}}{{- $_ := set $stores "parameterStore" ($ps.storeName | default "aws-parameter-store") -}}{{- end -}}
{{- if not $stores -}}
{{- fail "external-secrets-subchart: aws.enabled is true but neither aws.secretsManager.enabled nor aws.parameterStore.enabled is set" -}}
{{- end -}}
{{- if eq (get $stores "secretsManager") (get $stores "parameterStore") -}}
{{- fail "external-secrets-subchart: aws.secretsManager.storeName and aws.parameterStore.storeName must differ" -}}
{{- end -}}
{{- $defaultSource := $a.defaultSource | default (ternary "secretsManager" "parameterStore" (hasKey $stores "secretsManager")) -}}
{{- if not (hasKey $stores $defaultSource) -}}
{{- fail (printf "external-secrets-subchart: aws.defaultSource is %q, but aws.%s.enabled is false" $defaultSource $defaultSource) -}}
{{- end -}}
{{- toYaml (dict
  "serviceAccountName" (tpl ($a.serviceAccountName | default "{{ .Release.Name }}-secrets") .)
  "stores" $stores
  "defaultStore" (get $stores $defaultSource)) -}}
{{- end -}}
{{- end -}}

{{/*
Namespaced SecretStores to render: secretStores.items (if enabled) plus one store per enabled
aws service, all authenticating as the aws ServiceAccount.
Usage: include "eso-sub.secretStoreItems" $ | fromYaml
*/}}
{{- define "eso-sub.secretStoreItems" -}}
{{- $items := include "eso-sub.featureItems" (dict "root" . "feature" "secretStores") | fromYaml -}}
{{- with include "eso-sub.aws" . | fromYaml -}}
{{- $auth := dict "jwt" (dict "serviceAccountRef" (dict "name" .serviceAccountName)) -}}
{{- range $source, $storeName := .stores -}}
{{- if hasKey $items $storeName -}}
{{- fail (printf "external-secrets-subchart: aws.%s store %q is also defined in secretStores.items; rename one" $source $storeName) -}}
{{- end -}}
{{- $service := ternary "SecretsManager" "ParameterStore" (eq $source "secretsManager") -}}
{{- $aws := dict "service" $service "region" $.Values.aws.region "auth" (deepCopy $auth) -}}
{{- $_ := set $items $storeName (dict "provider" (dict "aws" $aws)) -}}
{{- end -}}
{{- end -}}
{{- toYaml $items -}}
{{- end -}}

{{/*
ServiceAccounts to render: serviceAccounts.items (if enabled) plus the aws shorthand account.
The shorthand account carries `fullName`, its exact rendered name (no namePrefix).
Usage: include "eso-sub.serviceAccountItems" $ | fromYaml
*/}}
{{- define "eso-sub.serviceAccountItems" -}}
{{- $items := include "eso-sub.featureItems" (dict "root" . "feature" "serviceAccounts") | fromYaml -}}
{{- with include "eso-sub.aws" . | fromYaml -}}
{{- if hasKey $items .serviceAccountName -}}
{{- fail (printf "external-secrets-subchart: aws service account %q is also defined in serviceAccounts.items; rename one" .serviceAccountName) -}}
{{- end -}}
{{- $_ := set $items .serviceAccountName (dict
  "roleArn" $.Values.aws.roleArn
  "annotations" ($.Values.aws.serviceAccountAnnotations | default dict)
  "fullName" .serviceAccountName) -}}
{{- end -}}
{{- toYaml $items -}}
{{- end -}}

{{/*
Fails when `name` is an item of a feature block that is switched off, so a reference to it
doesn't silently point at a store or account that will never exist.
Usage: include "eso-sub.requireFeature" (dict "root" $ "feature" "secretStores" "name" $n "desc" $desc)
*/}}
{{- define "eso-sub.requireFeature" -}}
{{- $f := index .root.Values .feature | default dict -}}
{{- if and (not $f.enabled) (hasKey ($f.items | default dict) .name) -}}
{{- fail (printf "external-secrets-subchart: %s references %q from %s.items, but %s.enabled is false" .desc .name .feature .feature) -}}
{{- end -}}
{{- end -}}

{{/*
Resolve a secretStoreRef. Order: `source` (aws service of this item), the item's own
secretStoreRef, defaults.secretStoreRef, then aws.defaultSource. Fails if no store name is set.
Pass "noAwsFallback" true where a namespaced aws store is unusable (ClusterExternalSecret).
Usage: include "eso-sub.storeRef" (dict "root" $ "ref" $item.secretStoreRef "source" $item.source "item" $name)
*/}}
{{- define "eso-sub.storeRef" -}}
{{- $d := .root.Values.defaults.secretStoreRef | default dict -}}
{{- $ref := .ref | default dict -}}
{{- $aws := include "eso-sub.aws" .root | fromYaml -}}
{{- if and .allowLabelSelector $ref.labelSelector -}}
{{- toYaml $ref -}}
{{- else -}}
{{- $name := $ref.name | default $d.name | default "" -}}
{{- $kind := $ref.kind | default $d.kind | default "SecretStore" -}}
{{- if .source -}}
{{- if $ref.name -}}
{{- fail (printf "external-secrets-subchart: %s sets both source and secretStoreRef; use one" .item) -}}
{{- end -}}
{{- if not $aws -}}
{{- fail (printf "external-secrets-subchart: %s has source %q, but aws.enabled is false" .item .source) -}}
{{- end -}}
{{- if not (hasKey $aws.stores .source) -}}
{{- fail (printf "external-secrets-subchart: %s has source %q, but aws.%s.enabled is false" .item .source .source) -}}
{{- end -}}
{{- $name = get $aws.stores .source -}}
{{- $kind = "SecretStore" -}}
{{- else if and (not $name) $aws (not .noAwsFallback) -}}
{{- $name = $aws.defaultStore -}}
{{- $kind = $ref.kind | default "SecretStore" -}}
{{- end -}}
{{- $name = tpl $name .root -}}
{{- if not (has $kind (list "SecretStore" "ClusterSecretStore")) -}}
{{- fail (printf "external-secrets-subchart: %s has secretStoreRef.kind %q; must be SecretStore or ClusterSecretStore" .item $kind) -}}
{{- end -}}
{{- if not $name -}}
{{- fail (printf "external-secrets-subchart: %s has no secretStoreRef.name and defaults.secretStoreRef.name is empty (or enable aws)" .item) -}}
{{- end -}}
{{- /* Stores defined in this chart get the same namePrefix as the store itself. */ -}}
{{- $isCluster := eq $kind "ClusterSecretStore" -}}
{{- $local := ternary (include "eso-sub.featureItems" (dict "root" .root "feature" "clusterSecretStores")) (include "eso-sub.secretStoreItems" .root) $isCluster | fromYaml -}}
{{- if hasKey $local $name -}}
{{- $name = include "eso-sub.name" (dict "root" .root "name" $name) -}}
{{- else -}}
{{- include "eso-sub.requireFeature" (dict "root" .root "feature" (ternary "clusterSecretStores" "secretStores" $isCluster) "name" $name "desc" .item) -}}
{{- end -}}
name: {{ $name }}
kind: {{ $kind }}
{{- end -}}
{{- end -}}

{{/*
Item enabled check: null items are skipped (lets an override file remove an entry),
otherwise enabled unless `enabled: false`.
Usage: include "eso-sub.enabled" (dict "item" $es "desc" (printf "ExternalSecret %q" $name))
*/}}
{{- define "eso-sub.enabled" -}}
{{- if not (kindIs "invalid" .item) -}}
{{- if not (kindIs "map" .item) -}}
{{- fail (printf "external-secrets-subchart: %s must be a map, got %s" .desc (kindOf .item)) -}}
{{- end -}}
{{- if or (not (hasKey .item "enabled")) .item.enabled -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
refreshInterval for an item, falling back to defaults. Uses hasKey so 0 (disable refresh) is kept.
Usage: include "eso-sub.refreshInterval" (dict "root" $ "item" $es)
*/}}
{{- define "eso-sub.refreshInterval" -}}
{{- if hasKey .item "refreshInterval" -}}
{{- .item.refreshInterval | toString | quote -}}
{{- else -}}
{{- .root.Values.defaults.refreshInterval | toString | quote -}}
{{- end -}}
{{- end -}}

{{/*
AWS provider auth: require an IAM role. Rejects static access keys (auth.secretRef).
When auth.jwt.serviceAccountRef names a ServiceAccount from this chart, that account
must set roleArn; its name gets namePrefix and, for ClusterSecretStores, its namespace.
Mutates .provider (pass a deepCopy). Renders nothing.
Usage: include "eso-sub.awsAuth" (dict "root" $ "provider" $p "kind" $kind "store" $s "desc" $desc)
*/}}
{{- define "eso-sub.awsAuth" -}}
{{- $aws := .provider.aws -}}
{{- if kindIs "map" $aws -}}
{{- $auth := $aws.auth | default dict -}}
{{- if $auth.secretRef -}}
{{- fail (printf "external-secrets-subchart: %s uses static AWS access keys (auth.secretRef). Use an IAM role: auth.jwt.serviceAccountRef with an IRSA ServiceAccount, or omit auth to use the ESO controller's role" .desc) -}}
{{- end -}}
{{- $saName := dig "jwt" "serviceAccountRef" "name" "" $auth -}}
{{- $accounts := include "eso-sub.serviceAccountItems" .root | fromYaml -}}
{{- if and $saName (hasKey $accounts $saName) -}}
{{- $sa := get $accounts $saName -}}
{{- if not (include "eso-sub.enabled" (dict "item" $sa "desc" (printf "ServiceAccount %q" $saName))) -}}
{{- fail (printf "external-secrets-subchart: %s uses ServiceAccount %q, which is disabled or removed" .desc $saName) -}}
{{- end -}}
{{- if not $sa.roleArn -}}
{{- fail (printf "external-secrets-subchart: %s uses ServiceAccount %q, which has no roleArn" .desc $saName) -}}
{{- end -}}
{{- $ref := $auth.jwt.serviceAccountRef -}}
{{- $saNamespace := $sa.namespace | default .root.Release.Namespace -}}
{{- if eq .kind "SecretStore" -}}
{{- if ne $saNamespace (.store.namespace | default .root.Release.Namespace) -}}
{{- fail (printf "external-secrets-subchart: %s and its ServiceAccount %q must be in the same namespace" .desc $saName) -}}
{{- end -}}
{{- else if not $ref.namespace -}}
{{- $_ := set $ref "namespace" $saNamespace -}}
{{- end -}}
{{- $_ := set $ref "name" ($sa.fullName | default (include "eso-sub.name" (dict "root" .root "name" $saName))) -}}
{{- else if $saName -}}
{{- include "eso-sub.requireFeature" (dict "root" .root "feature" "serviceAccounts" "name" $saName "desc" .desc) -}}
{{- end -}}
{{- end -}}
{{- end -}}
