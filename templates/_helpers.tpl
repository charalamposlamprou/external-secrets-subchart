{{/*
Chart name and version label value.
*/}}
{{- define "eso-sub.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
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
helm.sh/chart: {{ include "eso-sub.chart" .root }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: {{ .root.Release.Name }}
app.kubernetes.io/component: external-secrets
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- with .extra }}
{{ toYaml . }}
{{- end }}
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
{{- $name := tpl (($ref.name | default $d.name) | default "") .root -}}
{{- $kind := $ref.kind | default $d.kind | default "SecretStore" -}}
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

{{/*
Item enabled check: enabled unless explicitly false.
*/}}
{{- define "eso-sub.enabled" -}}
{{- if or (not (hasKey . "enabled")) .enabled -}}true{{- end -}}
{{- end -}}
