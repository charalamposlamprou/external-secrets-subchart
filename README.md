# external-secrets-subchart

[![lint](https://github.com/charalamposlamprou/external-secrets-subchart/actions/workflows/lint.yaml/badge.svg)](https://github.com/charalamposlamprou/external-secrets-subchart/actions/workflows/lint.yaml)

A Helm **subchart** that renders [External Secrets Operator](https://external-secrets.io) (ESO) custom resources from values. Add it as a dependency of your existing application chart, and declare your secrets in that chart's `values.yaml`, next to the rest of your app's configuration.

It does **not** install the operator. ESO and its CRDs must already be running in the cluster.

| Values key               | Renders                 | Scope      |
|--------------------------|-------------------------|------------|
| `secretStores`           | `SecretStore`           | Namespaced |
| `clusterSecretStores`    | `ClusterSecretStore`    | Cluster    |
| `externalSecrets`        | `ExternalSecret`        | Namespaced |
| `clusterExternalSecrets` | `ClusterExternalSecret` | Cluster    |
| `pushSecrets`            | `PushSecret`            | Namespaced |

Every collection is a **map keyed by resource name**, not a list. Helm merges maps across values files but replaces lists, so an environment file (`values-prod.yaml`) can change, disable or remove a single entry without copying the others.

## Requirements

- Helm 3.8+ (for OCI registries)
- External Secrets Operator ≥ 0.17, which serves `external-secrets.io/v1`. For older operators, set `apiVersion: external-secrets.io/v1beta1`.
- Cluster-scoped resources (`ClusterSecretStore`, `ClusterExternalSecret`) need a Helm release identity that is allowed to create them.

## Add it to your existing chart

### 1. Declare the dependency

From GitHub Container Registry (recommended, see [Releasing](#releasing)):

```yaml
# my-app/Chart.yaml
dependencies:
  - name: external-secrets-subchart
    version: 0.1.0
    repository: oci://ghcr.io/charalamposlamprou/charts
    alias: secrets               # optional: values live under `secrets:`
    condition: secrets.enabled
```

Or from a local checkout next to your chart, which is handy while developing:

```yaml
    repository: file://../external-secrets-subchart
```

Then fetch it. The package is public, so no login is needed:

```bash
helm dependency update ./my-app
```

To try a version on its own:

```bash
helm show values oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart --version 0.1.0
```

### 2. Configure secrets in your values

```yaml
# my-app/values.yaml
secrets:
  enabled: true
  defaults:
    secretStoreRef:
      name: vault-backend        # used by every item that doesn't set its own
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
              serviceAccountRef:
                name: my-app

  externalSecrets:
    my-app-env:                  # → Secret "my-app-env" with every key under my-app/env
      dataFrom:
        - extract:
            key: my-app/env
    db-credentials:              # → Secret "db-credentials" built from a template
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

### 3. Use the generated Secrets in your templates

```yaml
envFrom:
  - secretRef:
      name: my-app-env
```

A complete working example is in [`examples/parent-chart`](examples/parent-chart).

## Common setups

**Use a store that already exists in the cluster.** Leave `secretStores` empty and point at it:

```yaml
secrets:
  defaults:
    secretStoreRef: {name: aws-secrets-manager, kind: ClusterSecretStore}
  externalSecrets:
    my-app-env:
      dataFrom:
        - extract: {key: prod/my-app}
```

**AWS Secrets Manager with IRSA:**

```yaml
secrets:
  secretStores:
    aws:
      provider:
        aws:
          service: SecretsManager
          region: eu-west-1
          auth:
            jwt:
              serviceAccountRef:
                name: my-app
  defaults:
    secretStoreRef: {name: aws}
```

**Per-environment overrides** (`values-prod.yaml`):

```yaml
secrets:
  externalSecrets:
    my-app-env:
      dataFrom:
        - extract: {key: prod/my-app}   # replaces the list for this item only
    debug-token:
      enabled: false                    # keep the entry, render nothing
    legacy-secret: null                 # remove the entry entirely
```

## Values reference

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Master switch. `false` renders nothing. |
| `apiVersion` | `external-secrets.io/v1` | API version for stores, ExternalSecret and ClusterExternalSecret. |
| `pushSecretApiVersion` | `external-secrets.io/v1alpha1` | API version for PushSecret. |
| `namePrefix` | `""` | Prefix for every resource name. Rendered with `tpl`, e.g. `"{{ .Release.Name }}-"`. |
| `commonLabels` | `{}` | Labels added to every resource (an item's own `labels` win on conflict). |
| `commonAnnotations` | `{}` | Annotations added to every resource (an item's own `annotations` win on conflict). |
| `defaults.refreshInterval` | `1h` | Default for ExternalSecret and PushSecret. |
| `defaults.secretStoreRef.name` | `""` | Default store name (templatable). Required unless every item sets its own. |
| `defaults.secretStoreRef.kind` | `SecretStore` | `SecretStore` or `ClusterSecretStore`. |
| `defaults.target.creationPolicy` | `Owner` | Default ExternalSecret target creation policy. |
| `defaults.target.deletionPolicy` | `Retain` | Default ExternalSecret target deletion policy. |

### Per-item fields

Every item accepts `enabled` (default `true`), `labels` and `annotations`. Namespaced kinds also accept `namespace` (default: the release namespace).

| Collection | Fields |
|------------|--------|
| `secretStores.<name>`, `clusterSecretStores.<name>` | `provider` **(required)**, `extraSpec` (other spec fields such as `retrySettings`, `refreshInterval`, `conditions`; merged into `spec`, must not contain `provider`) |
| `externalSecrets.<name>` | `data` and/or `dataFrom` **(at least one required)**, `secretStoreRef`, `refreshInterval`, `refreshPolicy`, `target` (merged over `defaults.target`; `target.name` defaults to the resource name) |
| `clusterExternalSecrets.<name>` | `externalSecretSpec` **(required, full ExternalSecret spec, verbatim)**, `externalSecretName`, `namespaceSelectors`, `namespaces`, `refreshTime` |
| `pushSecrets.<name>` | `selector` and `data` **(required)**, `secretStoreRefs` (each by `name`/`kind` or by `labelSelector`; defaults to `[defaults.secretStoreRef]`), `refreshInterval`, `updatePolicy`, `deletionPolicy` |

## Behaviour notes

- **ESO templates vs Helm templates.** `target.template` in ExternalSecrets and `externalSecretSpec` in ClusterExternalSecrets are **not** run through Helm's `tpl`, so ESO's `{{ .key }}` syntax works as written. `namePrefix`, `secretStoreRef.name`, store `provider` and `extraSpec` **are** rendered with `tpl`, so `{{ .Release.Name }}` and friends work there.
- **Name prefix and references.** When a `secretStoreRef.name` matches a store defined in this chart, `namePrefix` is added to the reference automatically. References to stores defined elsewhere, and anything inside `clusterExternalSecrets.*.externalSecretSpec`, are used exactly as written.
- **Disabling refresh.** `refreshInterval: 0` (or `"0"`) is kept as is, so ESO fetches once and never refreshes. It does not fall back to the default.
- **Validation.** Rendering fails with an `external-secrets-subchart: …` message for a missing `provider`, `data`/`dataFrom`, `externalSecretSpec`, PushSecret `selector`/`data` or store name, an invalid store `kind`, or an item that isn't a map. Note that `helm lint` only reports these as `[INFO]`; use `helm template` to see them as errors.
- **Argo CD ordering.** To have stores sync before the ExternalSecrets that use them, give the stores `annotations: {argocd.argoproj.io/sync-wave: "-1"}`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `no matches for kind "ExternalSecret" in version "external-secrets.io/v1"` | ESO isn't installed, or is older than 0.17. Install/upgrade ESO, or set `apiVersion: external-secrets.io/v1beta1`. |
| `has no secretStoreRef.name and defaults.secretStoreRef.name is empty` | Set `defaults.secretStoreRef.name`, or `secretStoreRef` on that item. |
| ExternalSecret status `SecretSyncedError` | The store can't read the remote key. Check `kubectl describe externalsecret <name>` and the store's auth/permissions. |
| `helm dependency update` returns 401/403/404 from ghcr.io | The version hasn't been published yet, or the package is still private (see [Releasing](#releasing)). Check `oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart` and the version in your `Chart.yaml`. |
| Workflow job fails in seconds with no logs | GitHub didn't start the runner (Actions disabled, or billing/spending limit for private repos). The run page banner shows the reason. |

## Releasing

Charts are published to GitHub Container Registry as OCI artifacts by [`.github/workflows/release.yaml`](.github/workflows/release.yaml).

1. Bump `version` in `Chart.yaml` (e.g. `0.2.0`) and commit.
2. Tag and push. The tag must be `v` + the chart version, or the workflow fails before publishing:
   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```
3. The workflow lints and renders the chart, then pushes `oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart:0.2.0`.
4. Bump `version` in the consuming chart's `dependencies` and run `helm dependency update`.

**First release only:** GHCR creates new packages as **private**, even from a public repo. After the first tag is published, open your GitHub profile → **Packages** → `charts/external-secrets-subchart` → **Package settings** → **Change visibility** → **Public**. Later versions keep that visibility, and anyone can pull the chart without logging in.

Manual publish (without Actions; token needs `write:packages`):

```bash
echo "$TOKEN" | helm registry login ghcr.io -u charalamposlamprou --password-stdin
helm package . && helm push external-secrets-subchart-0.2.0.tgz oci://ghcr.io/charalamposlamprou/charts
```

## Development

```bash
helm lint . --strict -f ci/full-values.yaml
helm template test . -f ci/full-values.yaml          # surfaces validation failures
(cd examples/parent-chart && helm dependency update && helm template my-app .)
```

`ci/full-values.yaml` exercises every resource kind and the edge cases above. The `lint` workflow runs all three commands on every push and pull request.
