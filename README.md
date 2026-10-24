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
- For AWS: an EKS cluster with its [IAM OIDC provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) registered, so ServiceAccounts can assume IAM roles (IRSA). ESO's default RBAC already allows it to request tokens for those ServiceAccounts.
- Cluster-scoped resources (`ClusterSecretStore`, `ClusterExternalSecret`) need a Helm release identity that is allowed to create them.

## Add it to your existing chart

Each app gets **its own IAM role** that can read only that app's secrets. The subchart creates a dedicated ServiceAccount carrying the role (IRSA) and a SecretStore that authenticates as it. Only ESO uses that ServiceAccount (`automountServiceAccountToken: false`); your app's pods keep their own account and cannot assume the role.

```
ExternalSecret ──> SecretStore "aws" ──(auth.jwt)──> ServiceAccount "my-app-secrets" ──(IRSA)──> IAM role "my-app-secrets" ──> secrets under my-app/*
```

### 1. Create the app's IAM role

With the Terraform in [`examples/terraform/irsa-role`](examples/terraform/irsa-role):

```hcl
module "my_app_secrets_role" {
  source = "git::https://github.com/charalamposlamprou/external-secrets-subchart.git//examples/terraform/irsa-role?ref=v0.2.0"

  cluster_name = "my-cluster"
  app          = "my-app"       # role "my-app-secrets", reads secrets named my-app/*
  namespace    = "my-app"       # namespace of the Helm release
  # service_account      = "my-app-secrets"   # rendered name, including any namePrefix
  # secret_name_prefixes = ["my-app/", "shared/db-"]
  # kms_key_arns         = [aws_kms_key.secrets.arn]   # only for customer-managed keys
}

output "my_app_secrets_role_arn" {
  value = module.my_app_secrets_role.role_arn
}
```

The role trusts only `system:serviceaccount:<namespace>:<service_account>` through the cluster's OIDC provider, and allows `secretsmanager:GetSecretValue` and `DescribeSecret` on the given name prefixes. If you create the role another way, keep the same trust condition and permissions. Add `secretsmanager:ListSecrets` if you use `dataFrom.find`, and the `CreateSecret`/`PutSecretValue`/`TagResource` actions if you use PushSecrets.

### 2. Declare the dependency

From GitHub Container Registry (recommended, see [Releasing](#releasing)):

```yaml
# my-app/Chart.yaml
dependencies:
  - name: external-secrets-subchart
    version: 0.2.0
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
helm show values oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart --version 0.2.0
```

### 3. Configure the role and secrets in your values

```yaml
# my-app/values.yaml
secrets:
  enabled: true

  serviceAccounts:
    my-app-secrets:              # used only by ESO, never by your pods
      roleArn: arn:aws:iam::123456789012:role/my-app-secrets   # role_arn from step 1

  secretStores:
    aws:
      provider:                  # passed through verbatim — any ESO provider works
        aws:
          service: SecretsManager
          region: eu-west-1
          auth:
            jwt:
              serviceAccountRef:
                name: my-app-secrets   # the ServiceAccount above

  defaults:
    secretStoreRef:
      name: aws                  # used by every item that doesn't set its own
      kind: SecretStore

  externalSecrets:
    my-app-env:                  # → Secret "my-app-env" with every key in secret my-app/env
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

Rendering fails if an AWS store uses static access keys (`auth.secretRef`), or references a ServiceAccount from `serviceAccounts` that has no `roleArn`. Keep `roleArn` per environment in `values-<env>.yaml` if accounts differ.

### 4. Use the generated Secrets in your templates

```yaml
envFrom:
  - secretRef:
      name: my-app-env
```

### 5. Check it works

```bash
kubectl -n my-app get secretstore,externalsecret   # STATUS Valid / SecretSynced, READY True
kubectl -n my-app get secret my-app-env
```

A complete working example is in [`examples/parent-chart`](examples/parent-chart).

## Common setups

**Use a store that already exists in the cluster.** Leave `secretStores` and `serviceAccounts` empty and point at it. Whoever runs that store owns its IAM role:

```yaml
secrets:
  defaults:
    secretStoreRef: {name: aws-secrets-manager, kind: ClusterSecretStore}
  externalSecrets:
    my-app-env:
      dataFrom:
        - extract: {key: prod/my-app}
```

**Use the ESO controller's own IAM role** (one role shared by every app, simpler but less isolated). Omit `auth` and give the role to ESO's ServiceAccount (IRSA or EKS Pod Identity) when installing the operator:

```yaml
secrets:
  secretStores:
    aws:
      provider:
        aws: {service: SecretsManager, region: eu-west-1}
  defaults:
    secretStoreRef: {name: aws}
```

**HashiCorp Vault** (no IAM involved):

```yaml
secrets:
  secretStores:
    vault:
      provider:
        vault:
          server: https://vault.example.com
          path: secret
          version: v2
          auth:
            kubernetes: {mountPath: kubernetes, role: my-app, serviceAccountRef: {name: my-app}}
  defaults:
    secretStoreRef: {name: vault}
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
| `serviceAccounts` | `{}` | Dedicated ServiceAccounts for store auth, keyed by name. `roleArn` sets `eks.amazonaws.com/role-arn`. |
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
| `serviceAccounts.<name>` | `roleArn` (IAM role ARN, templatable). Rendered with `automountServiceAccountToken: false`. |
| `secretStores.<name>`, `clusterSecretStores.<name>` | `provider` **(required)**, `extraSpec` (other spec fields such as `retrySettings`, `refreshInterval`, `conditions`; merged into `spec`, must not contain `provider`) |
| `externalSecrets.<name>` | `data` and/or `dataFrom` **(at least one required)**, `secretStoreRef`, `refreshInterval`, `refreshPolicy`, `target` (merged over `defaults.target`; `target.name` defaults to the resource name) |
| `clusterExternalSecrets.<name>` | `externalSecretSpec` **(required, full ExternalSecret spec, verbatim except `secretStoreRef`, which is resolved like an ExternalSecret's)**, `externalSecretName`, `namespaceSelectors`, `namespaces`, `refreshTime` |
| `pushSecrets.<name>` | `selector` and `data` **(required)**, `secretStoreRefs` (each by `name`/`kind` or by `labelSelector`; defaults to `[defaults.secretStoreRef]`), `refreshInterval`, `updatePolicy`, `deletionPolicy` |

## Behaviour notes

- **ESO templates vs Helm templates.** `target.template` in ExternalSecrets and `externalSecretSpec` in ClusterExternalSecrets are **not** run through Helm's `tpl`, so ESO's `{{ .key }}` syntax works as written. `namePrefix`, `secretStoreRef.name`, store `provider` and `extraSpec` **are** rendered with `tpl`, so `{{ .Release.Name }}` and friends work there.
- **Name prefix and references.** When a `secretStoreRef.name` matches a store defined in this chart, `namePrefix` is added to the reference automatically. This applies to ExternalSecrets, PushSecrets and `clusterExternalSecrets.*.externalSecretSpec.secretStoreRef`, which also falls back to `defaults.secretStoreRef` when unset. References to stores defined elsewhere are used exactly as written.
- **IAM roles for AWS stores.** For any store with an `aws` provider, static keys (`auth.secretRef`) are rejected. When `auth.jwt.serviceAccountRef.name` matches an entry in `serviceAccounts`, that entry must set `roleArn`, must be in the same namespace as a `SecretStore`, and the reference gets `namePrefix` (plus `namespace` for a `ClusterSecretStore`). References to ServiceAccounts created elsewhere are used as written.
- **Disabling refresh.** `refreshInterval: 0` (or `"0"`) is kept as is, so ESO fetches once and never refreshes. It does not fall back to the default.
- **Schema.** `values.schema.json` checks types and rejects unknown keys, so `enabled: "false"`, a typo such as `datafrom:`, an invalid store `kind` or a non-string label value fails at `helm install`/`template`/`lint` time. Provider and ESO spec contents (`provider`, `target`, `data`, …) are not constrained, so any ESO provider works.
- **Validation.** Rendering fails with an `external-secrets-subchart: …` message for a missing `provider`, `data`/`dataFrom`, `externalSecretSpec`, PushSecret `selector`/`data` or store name, an invalid store `kind`, or an item that isn't a map. Note that `helm lint` only reports these as `[INFO]`; use `helm template` to see them as errors.
- **Argo CD ordering.** To have stores sync before the ExternalSecrets that use them, give the stores `annotations: {argocd.argoproj.io/sync-wave: "-1"}`.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `no matches for kind "ExternalSecret" in version "external-secrets.io/v1"` | ESO isn't installed, or is older than 0.17. Install/upgrade ESO, or set `apiVersion: external-secrets.io/v1beta1`. |
| `has no secretStoreRef.name and defaults.secretStoreRef.name is empty` | Set `defaults.secretStoreRef.name`, or `secretStoreRef` on that item. |
| SecretStore not `Valid`: `WebIdentityErr` / `AccessDenied ... AssumeRoleWithWebIdentity` | The role's trust policy doesn't match the ServiceAccount. It must allow `system:serviceaccount:<namespace>:<name>` exactly as rendered (including `namePrefix`) via the cluster's OIDC provider. Check `kubectl -n <ns> get sa <name> -o yaml` for the `eks.amazonaws.com/role-arn` annotation. |
| ExternalSecret `SecretSyncedError` with `AccessDeniedException` | The role can be assumed but can't read that secret: widen `secret_name_prefixes`, or add `kms:Decrypt` for a customer-managed KMS key. |
| ExternalSecret status `SecretSyncedError` (other errors) | The store can't read the remote key. Check `kubectl describe externalsecret <name>` and the store's auth/permissions. |
| `helm dependency update` returns 401/403/404 from ghcr.io | The version hasn't been published yet, or the package is still private (see [Releasing](#releasing)). Check `oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart` and the version in your `Chart.yaml`. |
| Workflow job fails in seconds with no logs | GitHub didn't start the runner (Actions disabled, or billing/spending limit for private repos). The run page banner shows the reason. |

## Releasing

Releases are automatic. [`.github/workflows/release.yaml`](.github/workflows/release.yaml) runs on every push to `main` and publishes when `Chart.yaml` has a `version` that has no `v<version>` tag yet. It lints and tests the chart, pushes `oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart:<version>`, then creates the `v<version>` tag and a GitHub Release with the packaged `.tgz` and generated notes. Pushes that don't change the version do nothing.

To release:

1. In your PR, bump `version` in `Chart.yaml` (e.g. `0.1.0` → `0.2.0`).
2. Merge it. The release appears under **Releases** a minute later.
3. Bump `version` in the consuming chart's `dependencies` and run `helm dependency update`.

A PR check (`version-bump` in the `lint` workflow, script [`ci/check-version-bump.sh`](ci/check-version-bump.sh)) fails if a PR changes anything that goes into the package (`Chart.yaml`, `values*`, `templates/`, `README.md`) while keeping a version that is already released, or lowers the version. Changes to `ci/`, `tests/`, `examples/` or workflows don't need a bump. To retry a failed release, re-run the workflow, or start it from **Actions → release → Run workflow**.

**First release only:** GHCR creates new packages as **private**, even from a public repo. After the first release, open https://github.com/users/charalamposlamprou/packages/container/charts%2Fexternal-secrets-subchart/settings (or your profile → **Packages** → `charts/external-secrets-subchart` → **Package settings**) and use **Danger Zone → Change visibility → Public**. Later versions keep that visibility, and anyone can pull the chart without logging in.

Manual publish (without Actions; token needs `write:packages`):

```bash
echo "$TOKEN" | helm registry login ghcr.io -u charalamposlamprou --password-stdin
helm package . && helm push external-secrets-subchart-0.2.0.tgz oci://ghcr.io/charalamposlamprou/charts
```

## Development

```bash
helm lint . --strict -f ci/full-values.yaml
tests/run.sh                                         # golden snapshots + expected failures
(cd examples/parent-chart && helm dependency update && helm template my-app .)
```

`tests/run.sh` needs only Helm and bash. It renders `ci/full-values.yaml` and every `tests/cases/*.values.yaml`, diffs each against its `*.golden.yaml`, and checks that invalid values fail with the expected message. After an intended template change, run `tests/run.sh --update` and review the golden diff. The `lint` workflow runs all three commands on every push and pull request.
