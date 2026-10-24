# external-secrets-subchart

[![lint](https://github.com/charalamposlamprou/external-secrets-subchart/actions/workflows/lint.yaml/badge.svg)](https://github.com/charalamposlamprou/external-secrets-subchart/actions/workflows/lint.yaml)

A Helm **subchart** that renders [External Secrets Operator](https://external-secrets.io) (ESO) resources from values. Add it as a dependency of your app's chart and describe everything about the app's secrets in **one block** of that chart's `values.yaml`: the app's IAM role, where secrets come from (AWS Secrets Manager and/or SSM Parameter Store), and which Kubernetes Secrets to build.

```yaml
# my-app/values.yaml
secrets:
  aws:
    enabled: true
    roleArn: arn:aws:iam::123456789012:role/my-app-secrets
    region: eu-west-1
    secretsManager: {enabled: true}
    parameterStore: {enabled: true}
  externalSecrets:
    enabled: true
    items:
      my-app-env:
        source: secretsManager
        dataFrom: [{extract: {key: my-app/env}}]
      my-app-config:
        source: parameterStore
        data: [{secretKey: LOG_LEVEL, remoteRef: {key: /my-app/log-level}}]
```

**Every feature is off until you enable it.** Each feature is a block with its own `enabled` flag; its entries go under `items`, keyed by resource name. A fresh install with default values renders nothing.

| Feature block            | Renders                                  | Scope      |
|--------------------------|------------------------------------------|------------|
| `aws`                    | IRSA `ServiceAccount` + one `SecretStore` per enabled service | Namespaced |
| `externalSecrets`        | `ExternalSecret` (remote → Kubernetes Secret) | Namespaced |
| `pushSecrets`            | `PushSecret` (Kubernetes Secret → remote) | Namespaced |
| `serviceAccounts`        | `ServiceAccount` for store auth (advanced) | Namespaced |
| `secretStores`           | `SecretStore`, any ESO provider (advanced) | Namespaced |
| `clusterSecretStores`    | `ClusterSecretStore` (advanced)          | Cluster    |
| `clusterExternalSecrets` | `ClusterExternalSecret` (advanced)       | Cluster    |

`items` are **maps keyed by resource name**, not lists. Helm merges maps across values files but replaces lists, so an environment file (`values-prod.yaml`) can change, disable or remove a single entry without copying the others.

It does **not** install the operator. ESO and its CRDs must already be running in the cluster.

## Requirements

- Helm 3.8+ (for OCI registries)
- External Secrets Operator ≥ 0.17, which serves `external-secrets.io/v1`. For older operators, set `apiVersion: external-secrets.io/v1beta1`.
- For AWS: an EKS cluster with its [IAM OIDC provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) registered, so ServiceAccounts can assume IAM roles (IRSA). ESO's default RBAC already allows it to request tokens for those ServiceAccounts.
- Cluster-scoped resources (`ClusterSecretStore`, `ClusterExternalSecret`) need a Helm release identity that is allowed to create them.

## Add it to your existing chart

Each app gets **its own IAM role** that can read only that app's secrets and parameters. The `aws` block creates a dedicated ServiceAccount carrying the role (IRSA) and a SecretStore per enabled service that authenticates as it. Only ESO uses that ServiceAccount (`automountServiceAccountToken: false`); your app's pods keep their own account and cannot assume the role.

```
                                    ┌─> SecretStore "aws-secrets-manager" ─┐
ExternalSecret ──(source)───────────┤                                      ├─> ServiceAccount "my-app-secrets" ──(IRSA)──> IAM role "my-app-secrets"
                                    └─> SecretStore "aws-parameter-store" ─┘                                              ├─> Secrets Manager: my-app/*
                                                                                                                          └─> Parameter Store: /my-app/*
```

### 1. Create the app's IAM role

With the Terraform in [`examples/terraform/irsa-role`](examples/terraform/irsa-role):

```hcl
module "my_app_secrets_role" {
  source = "git::https://github.com/charalamposlamprou/external-secrets-subchart.git//examples/terraform/irsa-role?ref=v0.3.0"

  cluster_name = "my-cluster"
  app          = "my-app"       # role "my-app-secrets"
  namespace    = "my-app"       # namespace of the Helm release

  secrets_manager = true        # reads secrets named my-app/*
  parameter_store = true        # reads parameters under /my-app/
  # secret_name_prefixes    = ["my-app/", "shared/db-"]
  # parameter_path_prefixes = ["/my-app/", "/shared/"]
  # allow_find              = true                  # needed for dataFrom.find
  # kms_key_arns            = [aws_kms_key.app.arn] # customer-managed keys only
  # service_account         = "my-app-secrets"      # if not "<app>-secrets"
}

output "my_app_secrets_role_arn" {
  value = module.my_app_secrets_role.role_arn
}
```

The role trusts only `system:serviceaccount:<namespace>:<service_account>` through the cluster's OIDC provider. The chart names that ServiceAccount `<release name>-secrets` (set `aws.serviceAccountName` to change it), so with a release named `my-app` the defaults line up. Permissions:

| Enabled | Actions | Resources |
|---------|---------|-----------|
| `secrets_manager` | `secretsmanager:GetSecretValue`, `DescribeSecret` | `secret_name_prefixes` (default `<app>/`) |
| `parameter_store` | `ssm:GetParameter`, `GetParameters`, `GetParametersByPath` | `parameter_path_prefixes` (default `/<app>/`) |
| `allow_find` | `secretsmanager:ListSecrets`, `ssm:DescribeParameters` | `*` (AWS can't scope these) |
| `kms_key_arns` | `kms:Decrypt` via Secrets Manager / SSM | the given keys |

If you create the role another way, keep the same trust condition and permissions. PushSecrets additionally need write actions (`secretsmanager:CreateSecret`/`PutSecretValue`/`TagResource`, or `ssm:PutParameter`/`AddTagsToResource`).

### 2. Declare the dependency

From GitHub Container Registry (recommended, see [Releasing](#releasing)):

```yaml
# my-app/Chart.yaml
dependencies:
  - name: external-secrets-subchart
    version: 0.3.0
    repository: oci://ghcr.io/charalamposlamprou/charts
    alias: secrets               # values live under `secrets:`
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

To see every option of a version:

```bash
helm show values oci://ghcr.io/charalamposlamprou/charts/external-secrets-subchart --version 0.3.0
```

### 3. Describe the app's secrets in one block

```yaml
# my-app/values.yaml
secrets:
  enabled: true

  aws:
    enabled: true
    roleArn: arn:aws:iam::123456789012:role/my-app-secrets   # role_arn from step 1
    region: eu-west-1
    secretsManager:
      enabled: true              # SecretStore "aws-secrets-manager"
    parameterStore:
      enabled: true              # SecretStore "aws-parameter-store"
    # defaultSource: secretsManager   # for items without `source`

  externalSecrets:
    enabled: true
    items:
      my-app-env:                # Secret "my-app-env" <- every key of secret my-app/env
        source: secretsManager
        dataFrom:
          - extract:
              key: my-app/env

      db-credentials:            # Secret "db-credentials" built from a template
        source: secretsManager
        refreshInterval: 30m
        target:
          template:
            data:
              DATABASE_URL: "postgres://{{ .username }}:{{ .password }}@db:5432/app"
        data:
          - secretKey: username
            remoteRef: {key: my-app/db, property: username}   # JSON field of the secret
          - secretKey: password
            remoteRef: {key: my-app/db, property: password}

      my-app-config:             # Secret "my-app-config" <- parameters
        source: parameterStore
        data:
          - secretKey: LOG_LEVEL
            remoteRef: {key: /my-app/log-level}               # one parameter
        dataFrom:
          - find:
              path: /my-app/config/                           # all parameters under a path (allow_find)

  pushSecrets:
    enabled: false               # turn on only if you push Secrets back to AWS
    items: {}
```

How an item picks its store:

| Item sets | Store used |
|-----------|------------|
| `source: secretsManager` / `source: parameterStore` | that aws store (the service must be enabled) |
| `secretStoreRef: {name, kind}` | that store, from this chart or already in the cluster |
| neither | `defaults.secretStoreRef`, else the `aws.defaultSource` store (Secrets Manager when enabled) |

Rendering fails, with an `external-secrets-subchart: …` message, if `aws` is enabled without `roleArn`, `region` or any service, if an item's `source` points at a disabled service, or if an AWS store would use static access keys. Keep `roleArn` per environment in `values-<env>.yaml` if accounts differ.

### 4. Use the generated Secrets in your templates

```yaml
envFrom:
  - secretRef:
      name: my-app-env
  - secretRef:
      name: my-app-config
```

### 5. Check it works

```bash
kubectl -n my-app get serviceaccount my-app-secrets -o jsonpath='{.metadata.annotations}'   # role ARN
kubectl -n my-app get secretstore,externalsecret   # Valid / SecretSynced, READY True
kubectl -n my-app get secret my-app-env my-app-config
```

A complete working example is in [`examples/parent-chart`](examples/parent-chart).

### Upgrading from 0.2

0.3 moves every collection into a feature block. Wrap existing entries in `enabled: true` + `items:`, and replace a hand-written IRSA ServiceAccount + AWS SecretStore with the `aws` block:

```yaml
# 0.2                                # 0.3
externalSecrets:                     externalSecrets:
  my-app-env: {...}                    enabled: true
                                       items:
                                         my-app-env: {...}
```

The old layout fails the schema check (`at '/externalSecrets': ...`), so nothing is silently dropped.

## Common setups

**Use a store that already exists in the cluster.** Leave `aws` off and point at it. Whoever runs that store owns its IAM role:

```yaml
secrets:
  defaults:
    secretStoreRef: {name: aws-secrets-manager, kind: ClusterSecretStore}
  externalSecrets:
    enabled: true
    items:
      my-app-env:
        dataFrom:
          - extract: {key: prod/my-app}
```

**Only Parameter Store.** Enable just that service; it becomes the default for every item:

```yaml
secrets:
  aws:
    enabled: true
    roleArn: arn:aws:iam::123456789012:role/my-app-secrets
    region: eu-west-1
    parameterStore: {enabled: true}
  externalSecrets:
    enabled: true
    items:
      my-app-config:
        dataFrom:
          - find: {path: /my-app/}
```

**HashiCorp Vault or another provider** (advanced blocks, no IAM involved):

```yaml
secrets:
  secretStores:
    enabled: true
    items:
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
  externalSecrets:
    enabled: true
    items:
      my-app-env:
        dataFrom: [{extract: {key: my-app/env}}]
```

**Per-environment overrides** (`values-prod.yaml`):

```yaml
secrets:
  aws:
    roleArn: arn:aws:iam::210987654321:role/my-app-secrets   # prod account
  externalSecrets:
    items:
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
| `namePrefix` | `""` | Prefix for every resource name except the aws ServiceAccount. Rendered with `tpl`, e.g. `"{{ .Release.Name }}-"`. |
| `commonLabels` | `{}` | Labels added to every resource (an item's own `labels` win on conflict). |
| `commonAnnotations` | `{}` | Annotations added to every resource (an item's own `annotations` win on conflict). |
| `defaults.refreshInterval` | `1h` | Default for ExternalSecret and PushSecret. |
| `defaults.secretStoreRef.name` | `""` | Default store name (templatable). When empty, the aws default store is used if `aws` is enabled. |
| `defaults.secretStoreRef.kind` | `SecretStore` | `SecretStore` or `ClusterSecretStore`. |
| `defaults.target.creationPolicy` | `Owner` | Default ExternalSecret target creation policy. |
| `defaults.target.deletionPolicy` | `Retain` | Default ExternalSecret target deletion policy. |
| `aws.enabled` | `false` | Create the app's IRSA ServiceAccount and AWS SecretStores. |
| `aws.roleArn` | `""` | IAM role ARN (templatable). Required when enabled. |
| `aws.region` | `""` | AWS region. Required when enabled. |
| `aws.serviceAccountName` | `<release>-secrets` | Exact ServiceAccount name (templatable, no `namePrefix`). Must match the role's trust policy. |
| `aws.serviceAccountAnnotations` | `{}` | Extra ServiceAccount annotations. |
| `aws.secretsManager.enabled` / `.storeName` | `false` / `aws-secrets-manager` | Secrets Manager store. |
| `aws.parameterStore.enabled` / `.storeName` | `false` / `aws-parameter-store` | Parameter Store store. |
| `aws.defaultSource` | Secrets Manager if enabled | Store for items without `source`/`secretStoreRef` (and no `defaults.secretStoreRef.name`). |
| `<feature>.enabled` | `false` | Turns a feature block on. |
| `<feature>.items` | `{}` | The feature's entries, keyed by resource name. |

### Per-item fields

Every item accepts `enabled` (default `true`, so an override file can switch one off), `labels` and `annotations`. Namespaced kinds also accept `namespace` (default: the release namespace).

| Feature | Item fields |
|---------|-------------|
| `externalSecrets.items.<name>` | `data` and/or `dataFrom` **(at least one required)**, `source` (`secretsManager`/`parameterStore`) or `secretStoreRef`, `refreshInterval`, `refreshPolicy`, `target` (merged over `defaults.target`; `target.name` defaults to the resource name) |
| `pushSecrets.items.<name>` | `selector` and `data` **(required)**, `source` or `secretStoreRefs` (each by `name`/`kind` or by `labelSelector`; default: the default store), `refreshInterval`, `updatePolicy`, `deletionPolicy` |
| `serviceAccounts.items.<name>` | `roleArn` (IAM role ARN, templatable). Rendered with `automountServiceAccountToken: false`. |
| `secretStores.items.<name>`, `clusterSecretStores.items.<name>` | `provider` **(required)**, `extraSpec` (other spec fields such as `retrySettings`, `refreshInterval`, `conditions`; merged into `spec`, must not contain `provider`) |
| `clusterExternalSecrets.items.<name>` | `externalSecretSpec` **(required, full ExternalSecret spec, verbatim except `secretStoreRef`, which is resolved like an ExternalSecret's but never falls back to the namespaced aws stores)**, `externalSecretName`, `namespaceSelectors`, `namespaces`, `refreshTime` |

## Behaviour notes

- **Opt-in features.** Items of a feature block render only when that block has `enabled: true`. Referencing a store or ServiceAccount whose feature block is off fails rendering instead of producing a dangling reference.
- **ESO templates vs Helm templates.** `target.template` in ExternalSecrets and `externalSecretSpec` in ClusterExternalSecrets are **not** run through Helm's `tpl`, so ESO's `{{ .key }}` syntax works as written. `namePrefix`, `secretStoreRef.name`, `aws.roleArn`, `aws.serviceAccountName`, store `provider` and `extraSpec` **are** rendered with `tpl`, so `{{ .Release.Name }}` and friends work there.
- **Name prefix and references.** When a `secretStoreRef.name` matches a store defined in this chart (including the aws stores), `namePrefix` is added to the reference automatically. This applies to ExternalSecrets, PushSecrets and `clusterExternalSecrets.items.*.externalSecretSpec.secretStoreRef`. References to stores defined elsewhere are used exactly as written.
- **IAM roles for AWS stores.** For any store with an `aws` provider, static keys (`auth.secretRef`) are rejected. In the advanced blocks, when `auth.jwt.serviceAccountRef.name` matches an entry in `serviceAccounts.items`, that entry must set `roleArn`, must be in the same namespace as a `SecretStore`, and the reference gets `namePrefix` (plus `namespace` for a `ClusterSecretStore`). References to ServiceAccounts created elsewhere are used as written.
- **Secrets Manager vs Parameter Store keys.** Secrets Manager `remoteRef.key` is the secret name (`my-app/db`), with `property` selecting a JSON field. Parameter Store keys are parameter paths with a leading slash (`/my-app/log-level`); `dataFrom.find.path` reads every parameter under a path.
- **Disabling refresh.** `refreshInterval: 0` (or `"0"`) is kept as is, so ESO fetches once and never refreshes. It does not fall back to the default.
- **Schema.** `values.schema.json` checks types and rejects unknown keys, so `enabled: "true"`, a typo such as `datafrom:`, an unknown `source`, an invalid store `kind`, a malformed `roleArn`, a non-string label value or the 0.2 layout fails at `helm install`/`template`/`lint` time. Provider and ESO spec contents (`provider`, `target`, `data`, …) are not constrained, so any ESO provider works.
- **Validation.** Rendering fails with an `external-secrets-subchart: …` message for a missing `provider`, `data`/`dataFrom`, `externalSecretSpec`, PushSecret `selector`/`data`, store name or aws setting, a conflicting `source` + `secretStoreRef`, an invalid store `kind`, or an item that isn't a map. Note that `helm lint` only reports these as `[INFO]`; use `helm template` to see them as errors.
- **Argo CD ordering.** To have stores sync before the ExternalSecrets that use them, give the stores `annotations: {argocd.argoproj.io/sync-wave: "-1"}` (or set it in `commonAnnotations` for the ServiceAccount and stores, and override it per ExternalSecret).

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Nothing renders | The feature block isn't enabled. Set `externalSecrets.enabled: true` (and `aws.enabled`, `aws.secretsManager.enabled`, …). |
| `at '/externalSecrets': ...` schema error after upgrading | Values still use the 0.2 layout; see [Upgrading from 0.2](#upgrading-from-02). |
| `no matches for kind "ExternalSecret" in version "external-secrets.io/v1"` | ESO isn't installed, or is older than 0.17. Install/upgrade ESO, or set `apiVersion: external-secrets.io/v1beta1`. |
| `has no secretStoreRef.name and defaults.secretStoreRef.name is empty (or enable aws)` | Enable `aws`, set `source` or `secretStoreRef` on that item, or set `defaults.secretStoreRef.name`. |
| SecretStore not `Valid`: `WebIdentityErr` / `AccessDenied ... AssumeRoleWithWebIdentity` | The role's trust policy doesn't match the ServiceAccount. It must allow `system:serviceaccount:<namespace>:<name>` exactly as rendered (`<release>-secrets` by default) via the cluster's OIDC provider. Check `kubectl -n <ns> get sa <name> -o yaml` for the `eks.amazonaws.com/role-arn` annotation. |
| ExternalSecret `SecretSyncedError` with `AccessDeniedException` | The role can be assumed but can't read that secret or parameter: widen `secret_name_prefixes` / `parameter_path_prefixes`, set `allow_find` for `dataFrom.find`, or add `kms_key_arns` for a customer-managed KMS key. |
| ExternalSecret `SecretSyncedError` with `ParameterNotFound` / `ResourceNotFoundException` | Wrong key or region. Parameter keys need the leading `/`; check `aws.region`. |
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
