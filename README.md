# external-secrets-subchart

A Helm **subchart** that renders [External Secrets Operator](https://external-secrets.io) (ESO) custom resources from values. Add it as a dependency of your existing application chart, and declare your secrets in that chart's `values.yaml`.

It does **not** install the operator. ESO and its CRDs must already be running in the cluster.

| Values key               | Renders                 |
|--------------------------|-------------------------|
| `secretStores`           | `SecretStore`           |
| `clusterSecretStores`    | `ClusterSecretStore`    |
| `externalSecrets`        | `ExternalSecret`        |
| `clusterExternalSecrets` | `ClusterExternalSecret` |
| `pushSecrets`            | `PushSecret`            |

Every collection is a **map keyed by resource name**, not a list. That lets environment values files (`values-prod.yaml`, …) override or disable a single entry (`enabled: false`) without repeating the whole list.

## Requirements

- Helm 3.8+
- External Secrets Operator ≥ 0.17 (`external-secrets.io/v1`). For older operators, set `apiVersion: external-secrets.io/v1beta1`.

## Add it to your existing chart

```yaml
# my-app/Chart.yaml
dependencies:
  - name: external-secrets-subchart
    version: 0.1.0
    repository: file://../external-secrets-subchart   # or oci://ghcr.io/<you>/charts
    alias: secrets               # optional: shorter values key
    condition: secrets.enabled
```

```bash
helm dependency update ./my-app
```

```yaml
# my-app/values.yaml
secrets:
  enabled: true
  defaults:
    secretStoreRef:
      name: vault-backend        # used by every ExternalSecret that doesn't set its own
      kind: SecretStore

  secretStores:
    vault-backend:
      provider:                  # passed through verbatim — any ESO provider works
        vault:
          server: https://vault.example.com
          path: secret
          version: v2
          auth:
            kubernetes:
              mountPath: kubernetes
              role: my-app

  externalSecrets:
    my-app-env:                  # creates Secret "my-app-env"
      dataFrom:
        - extract:
            key: my-app/env
    db-credentials:
      refreshInterval: 30m
      target:
        template:
          data:
            DATABASE_URL: "postgres://{{ .username }}:{{ .password }}@db:5432/app"
      data:
        - secretKey: username
          remoteRef: {key: my-app/db, property: username}
        - secretKey: password
          remoteRef: {key: my-app/db, property: password}
```

Your Deployment can then use the generated Secret:

```yaml
envFrom:
  - secretRef:
      name: my-app-env
```

If you already have a `SecretStore` / `ClusterSecretStore` managed somewhere else, leave `secretStores` empty and just point `defaults.secretStoreRef` (or each item's `secretStoreRef`) at it.

A complete working example is in [`examples/parent-chart`](examples/parent-chart).

## Values reference

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Master switch for the subchart. |
| `apiVersion` | `external-secrets.io/v1` | API version for stores and ExternalSecrets. |
| `pushSecretApiVersion` | `external-secrets.io/v1alpha1` | API version for PushSecret. |
| `namePrefix` | `""` | Prefix for every resource name. Rendered with `tpl`, e.g. `"{{ .Release.Name }}-"`. |
| `commonLabels` / `commonAnnotations` | `{}` | Added to every resource. |
| `defaults.refreshInterval` | `1h` | Default for ExternalSecret / PushSecret. |
| `defaults.secretStoreRef.name` / `.kind` | `""` / `SecretStore` | Default store reference (templatable). |
| `defaults.target.creationPolicy` | `Owner` | Default ExternalSecret target creation policy. |
| `defaults.target.deletionPolicy` | `Retain` | Default ExternalSecret target deletion policy. |

### Per-item fields

**`secretStores.<name>` / `clusterSecretStores.<name>`**: `enabled`, `namespace` (SecretStore only), `labels`, `annotations`, `provider` (required, verbatim, templatable), `extraSpec` (any other spec fields, merged into `spec`).

**`externalSecrets.<name>`**: `enabled`, `namespace`, `labels`, `annotations`, `refreshInterval`, `refreshPolicy`, `secretStoreRef`, `target` (merged over `defaults.target`; `target.name` defaults to the resource name), `data`, `dataFrom` (at least one of these is required).

**`clusterExternalSecrets.<name>`**: `enabled`, `labels`, `annotations`, `externalSecretName`, `namespaceSelectors`, `namespaces`, `refreshTime`, `externalSecretSpec` (required, verbatim).

**`pushSecrets.<name>`**: `enabled`, `namespace`, `labels`, `annotations`, `refreshInterval`, `updatePolicy`, `deletionPolicy`, `secretStoreRefs` (defaults to `[defaults.secretStoreRef]`), `selector`, `data` (both required).

### Notes

- **ESO templates vs Helm templates.** `target.template` in ExternalSecrets and `externalSecretSpec` in ClusterExternalSecrets are **not** run through Helm's `tpl`, so ESO's `{{ .key }}` syntax works as is. `provider`, `extraSpec`, `namePrefix` and `secretStoreRef.name` **are** rendered with `tpl`, so you can use `{{ .Release.Name }}` etc. there.
- **Name prefix and references.** If a `secretStoreRef.name` matches a store defined in this chart's `secretStores` / `clusterSecretStores`, `namePrefix` is applied to the reference automatically. References inside `clusterExternalSecrets.*.externalSecretSpec` are passed through verbatim, so write the full name there.
- **Argo CD.** To have stores sync before ExternalSecrets, add `annotations: {argocd.argoproj.io/sync-wave: "-1"}` to the stores.
- The chart fails at render time with a clear message if a required field or store reference is missing.

## Development

```bash
helm lint . --strict -f ci/full-values.yaml
helm template test . -f ci/full-values.yaml
```

## Releasing

Charts are published to GitHub Container Registry as OCI artifacts by `.github/workflows/release.yaml`.

1. Bump `version` in `Chart.yaml` (e.g. `0.2.0`) and commit.
2. Tag and push. The tag must be `v` + the chart version, or the workflow fails:
   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```
3. The chart is pushed to `oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart:0.2.0`.

Consume it from your app chart:

```yaml
dependencies:
  - name: external-secrets-subchart
    version: 0.2.0
    repository: oci://ghcr.io/charalamposlamprou/charts
```

The package is private, like the repo. To pull it, run `helm registry login ghcr.io` with a token that has `read:packages`. For another repo's GitHub Actions, grant that repo access in the package settings (Manage Actions access), then log in with its `GITHUB_TOKEN`.

Manual publish (without Actions):

```bash
echo "$TOKEN" | helm registry login ghcr.io -u charalamposlamprou --password-stdin   # needs write:packages
helm package . && helm push external-secrets-subchart-0.1.0.tgz oci://ghcr.io/charalamposlamprou/charts
```
