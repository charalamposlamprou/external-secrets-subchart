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
Resolve a secretStoreRef, falling back to defaults. Fails if no store name is set.
Usage: include "eso-sub.storeRef" (dict "root" $ "ref" $item.secretStoreRef "item" $name)
*/}}
{{- define "eso-sub.storeRef" -}}
{{- $d := .root.Values.defaults.secretStoreRef | default dict -}}
{{- $ref := .ref | default dict -}}
{{- if and .allowLabelSelector $ref.labelSelector -}}
{{- toYaml $ref -}}
{{- else -}}
{{- $name := tpl (($ref.name | default $d.name) | default "") .root -}}
{{- $kind := $ref.kind | default $d.kind | default "SecretStore" -}}
{{- if not (has $kind (list "SecretStore" "ClusterSecretStore")) -}}
{{- fail (printf "external-secrets-subchart: %s has secretStoreRef.kind %q; must be SecretStore or ClusterSecretStore" .item $kind) -}}
{{- end -}}
{{- if not $name -}}
{{- fail (printf "external-secrets-subchart: %s has no secretStoreRef.name and defaults.secretStoreRef.name is empty" .item) -}}
{{- end -}}
{{- /* Stores defined in this chart get the same namePrefix as the store itself. */ -}}
{{- $local := ternary .root.Values.clusterSecretStores .root.Values.secretStores (eq $kind "ClusterSecretStore") | default dict -}}
{{- if hasKey $local $name -}}
{{- $name = include "eso-sub.name" (dict "root" .root "name" $name) -}}
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
{{- $accounts := .root.Values.serviceAccounts | default dict -}}
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
{{- $_ := set $ref "name" (include "eso-sub.name" (dict "root" .root "name" $saName)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
