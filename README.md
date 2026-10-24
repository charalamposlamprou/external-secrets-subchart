# external-secrets-subchart

[![lint](https://github.com/charalamposlamprou/external-secrets-subchart/actions/workflows/lint.yaml/badge.svg)](https://github.com/charalamposlamprou/external-secrets-subchart/actions/workflows/lint.yaml)

A Helm **subchart** that turns AWS SSM Parameter Store parameters and AWS Secrets Manager secrets into Kubernetes Secrets, using [External Secrets Operator](https://external-secrets.io) (ESO) and **one IAM role per app**. Add it as a dependency of your app's chart and list the app's secrets in one block of its `values.yaml`, grouped by where they come from:

```yaml
# my-app/values.yaml
secrets:
  aws:
    roleArn: arn:aws:iam::123456789012:role/my-cluster-my-app-secrets
    region: eu-west-1

  parameterStore:
    enabled: true
    secrets:
      my-app-config:                  # Kubernetes Secret "my-app-config"
        LOG_LEVEL: /my-app/log-level  #   key LOG_LEVEL <- parameter /my-app/log-level
        API_URL: /my-app/api-url
      my-app-flags:
        fromPath: /my-app/flags/      # every parameter under the path

  secretsManager:
    enabled: true
    secrets:
      my-app-env:
        fromSecret: my-app/env        # every JSON field of the secret
      my-app-db:
        DB_USER: {key: my-app/db, property: username}
        DB_PASS: {key: my-app/db, property: password}
```

That's the whole setup. From it the chart renders:

- the IRSA ServiceAccount `<release>-secrets` that carries the role,
- a SecretStore for each enabled service, and
- one ExternalSecret per entry.

**Every feature is off until you enable it**, so default values render nothing. The full ESO resources stay available as [advanced blocks](#advanced-full-eso-resources) for templates, other providers and cluster-scoped resources.

It does **not** install the operator. ESO and its CRDs must already be running in the cluster.

## Requirements

- Helm 3.16+ (CI tests 3.16, 3.22 and 4.3)
- External Secrets Operator ≥ 0.17 (serves `external-secrets.io/v1`). Every release of this chart is validated in CI against the CRDs of ESO **0.17.0** and **2.14.0**.
- An EKS cluster with its [IAM OIDC provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) registered, so ServiceAccounts can assume IAM roles (IRSA). ESO's default RBAC already allows it to request tokens for those ServiceAccounts.

## Add it to your existing chart

Each app gets **its own IAM role** that can read only that app's parameters and secrets. Only ESO uses the role's ServiceAccount (`automountServiceAccountToken: false`). Your app's pods keep their own account and can't assume the role.

```
parameterStore.secrets.* ─> SecretStore "my-app-parameter-store" ─┐
                                                                  ├─> ServiceAccount "my-app-secrets" ─(IRSA)─> IAM role "my-cluster-my-app-secrets"
secretsManager.secrets.* ─> SecretStore "my-app-secrets-manager" ─┘                                            ├─> Parameter Store: /my-app/*
                                                                                                               └─> Secrets Manager: my-app/*
```

### 1. Create the app's IAM role

With the Terraform in [`examples/terraform/irsa-role`](examples/terraform/irsa-role):

```hcl
module "my_app_secrets_role" {
  source = "git::https://github.com/charalamposlamprou/external-secrets-subchart.git//examples/terraform/irsa-role?ref=v0.5.1"

  cluster_name = "my-cluster"
  app          = "my-app"       # role "my-cluster-my-app-secrets"
  namespace    = "my-app"       # namespace of the Helm release

  parameter_store = true        # reads parameters under /my-app/
  secrets_manager = true        # reads secrets named my-app/*
  # parameter_path_prefixes = ["/my-app/", "/shared/"]
  # secret_name_prefixes    = ["my-app/", "shared/db-"]
  # kms_key_arns            = [aws_kms_key.app.arn] # customer-managed keys only
  # service_account         = "my-app-secrets"      # if not "<app>-secrets"
  # role_name               = "my-app-secrets"      # default "<cluster_name>-<app>-secrets"
  # permissions_boundary    = "arn:aws:iam::123456789012:policy/boundary"
  # tags                    = {team = "payments"}
}

output "my_app_secrets_role_arn" {
  value = module.my_app_secrets_role.role_arn
}
```

The role trusts only `system:serviceaccount:<namespace>:<service_account>` through the cluster's OIDC provider. The chart names that ServiceAccount `<release name>-secrets` (change it with `aws.serviceAccountName`), so with a release named `my-app` the defaults line up.

| Enabled | Actions | Resources |
|---------|---------|-----------|
| `parameter_store` | `ssm:GetParameter`, `GetParameters`, `GetParametersByPath` (used by `fromPath`) | `parameter_path_prefixes` (default `/<app>/`) |
| `secrets_manager` | `secretsmanager:GetSecretValue`, `DescribeSecret` | `secret_name_prefixes` (default `<app>/`) |
| `kms_key_arns` | `kms:Decrypt` through SSM / Secrets Manager | the given keys |
| `allow_find` | `secretsmanager:ListSecrets` | `*`. Only for Secrets Manager `find` in [advanced items](#advanced-full-eso-resources). |

The role is named `<cluster_name>-<app>-secrets` by default, because IAM role names are unique per AWS account and several clusters (dev, staging, …) often share one. If you create the role another way, keep the same trust condition and permissions.

### 2. Declare the dependency

```yaml
# my-app/Chart.yaml
dependencies:
  - name: external-secrets-subchart
    version: 0.5.1
    repository: oci://ghcr.io/charalamposlamprou/charts
    alias: secrets               # values live under `secrets:`
    condition: secrets.enabled
```

For a local checkout next to your chart, use `repository: file://../external-secrets-subchart`. Then fetch it. The package is public, so no login is needed:

```bash
helm dependency update ./my-app
```

### 3. List the app's secrets

```yaml
# my-app/values.yaml
secrets:
  aws:
    roleArn: arn:aws:iam::123456789012:role/my-cluster-my-app-secrets   # role_arn from step 1
    region: eu-west-1

  parameterStore:
    enabled: true
    refreshInterval: 1h          # optional, for every entry in this block
    secrets:
      my-app-config:
        LOG_LEVEL: /my-app/log-level
        API_URL: /my-app/api-url
      my-app-flags:
        fromPath: /my-app/flags/   # /my-app/flags/FEATURE_X -> key FEATURE_X
        refreshInterval: 5m        # optional, per entry

  secretsManager:
    enabled: true
    secrets:
      my-app-env:
        fromSecret: my-app/env     # {"A": "1", "B": "2"} -> keys A, B
      my-app-db:
        DB_USER: {key: my-app/db, property: username}   # one JSON field
        DB_PASS: {key: my-app/db, property: password}
        API_TOKEN: my-app/api-token                     # a plain-text secret
```

Each entry under `secrets` is one Kubernetes Secret with the same name. Inside an entry, every line is `SECRET_KEY: <where it comes from>`:

| Write | Means |
|-------|-------|
| `KEY: /path/name` (Parameter Store) or `KEY: secret-name` (Secrets Manager) | the whole value |
| `KEY: {key: secret-name, property: field}` | one JSON field (Secrets Manager, or a JSON parameter) |
| `KEY: {key: secret-name, version: AWSPREVIOUS}` | a specific version or label |
| `fromPath: /my-app/flags/` (Parameter Store) | every parameter under the path. The path prefix is stripped from key names, and deeper `/` become `_`. |
| `fromSecret: my-app/env` (Secrets Manager) | every field of a JSON secret |
| `refreshInterval: 5m` | how often ESO re-reads (`0` = once). Defaults to the block's `refreshInterval`, then `defaults.refreshInterval` (1h). |
| `type: kubernetes.io/dockerconfigjson` | the Kubernetes Secret type (default `Opaque`) |
| `template: {DATABASE_URL: "postgres://{{ .DB_USER }}@db/app"}` | extra keys built with [ESO templates](https://external-secrets.io/latest/guides/templating/) from the fetched keys. The fetched keys are kept too. |
| `enabled: false` | keep the entry but don't render it (handy in `values-<env>.yaml`) |

Secret keys may use letters, digits, `-`, `_` and `.`. The option names `enabled`, `refreshInterval`, `type`, `template` and `fromPath`/`fromSecret` are reserved, so a Secret key can't be called that; use the [advanced block](#advanced-full-eso-resources) if you need one. A Secret name may appear only once across both blocks. Rendering fails with an `external-secrets-subchart: …` message if a block is enabled without `aws.roleArn`/`aws.region`, an entry has no keys, or a value isn't a name or `{key: …}`.

### 4. Use the generated Secrets in your templates

```yaml
envFrom:
  - secretRef: {name: my-app-config}
  - secretRef: {name: my-app-flags}
  - secretRef: {name: my-app-env}
  - secretRef: {name: my-app-db}
```

### 5. Check it works

```bash
kubectl -n my-app get serviceaccount my-app-secrets -o jsonpath='{.metadata.annotations}'   # role ARN
kubectl -n my-app get secretstore,externalsecret   # Valid / SecretSynced, READY True
kubectl -n my-app get secret my-app-config -o jsonpath='{.data}'
```

A complete working example is in [`examples/parent-chart`](examples/parent-chart).

### Restart pods when secrets change

ESO updates the Kubernetes Secret on every refresh, but pods that read it through `envFrom`/`env` keep the old values until they restart. With [Stakater Reloader](https://github.com/stakater/Reloader) installed in the cluster, annotate your Deployment so it rolls when its Secrets change:

```yaml
# my-app/templates/deployment.yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "my-app-config,my-app-env"
```

Secrets mounted as volumes update in place without a restart, after the kubelet's sync delay.

### Per-environment overrides

`values-prod.yaml` only needs what differs. Maps merge across files, so other entries are kept:

```yaml
secrets:
  aws:
    roleArn: arn:aws:iam::210987654321:role/my-cluster-my-app-secrets   # prod account
  parameterStore:
    secrets:
      my-app-config:
        LOG_LEVEL: /my-app/prod/log-level    # replace one key
      my-app-flags:
        enabled: false                       # keep the entry, render nothing
      legacy: null                           # remove the entry entirely
```

### One AWS account per environment

When dev, staging and prod are separate AWS accounts (each with its own EKS cluster), every account gets its own copy of the app's IAM role, and only the role ARN differs between environments. Secret and parameter names can stay the same in every account, because the accounts already keep them apart.

**Terraform:** apply the [`irsa-role`](examples/terraform/irsa-role) module once per account, with that account's AWS provider and that environment's cluster:

```hcl
# environments/dev/main.tf (provider configured for the dev account)
module "my_app_secrets_role" {
  source = "git::https://github.com/charalamposlamprou/external-secrets-subchart.git//examples/terraform/irsa-role?ref=v0.5.1"

  cluster_name    = "dev"            # the dev account's EKS cluster
  app             = "my-app"
  namespace       = "my-app"
  parameter_store = true
  secrets_manager = true
}
# -> role_arn = arn:aws:iam::111111111111:role/dev-my-app-secrets
# environments/prod/main.tf: the same block with cluster_name = "prod", applied with the prod provider
```

**Values:** keep everything shared in `values.yaml` and put only the role ARN (and the region, if it differs) in each environment's file:

```yaml
# my-app/values.yaml (every environment)
secrets:
  aws:
    region: eu-west-1
  parameterStore:
    enabled: true
    secrets:
      my-app-config:
        LOG_LEVEL: /my-app/log-level      # same name in every account
  secretsManager:
    enabled: true
    secrets:
      my-app-env:
        fromSecret: my-app/env
```

```yaml
# my-app/values-dev.yaml
secrets:
  aws:
    roleArn: arn:aws:iam::111111111111:role/dev-my-app-secrets
```

```yaml
# my-app/values-prod.yaml
secrets:
  aws:
    roleArn: arn:aws:iam::210987654321:role/prod-my-app-secrets
```

```bash
helm upgrade --install my-app ./my-app -n my-app -f my-app/values.yaml -f my-app/values-prod.yaml
```

Each environment's role trusts only its own cluster's OIDC provider and grants access only within its own account, so dev can't read prod's secrets. If an environment encrypts with a customer-managed KMS key, pass that account's key in `kms_key_arns` for that environment.

## How this compares to other approaches

This layout is built from common patterns:

- **Opt-in blocks with a map of Secrets keyed by name**, as in [Stakater's `application` chart](https://github.com/stakater/application) (`externalSecret.enabled`, a default store and refresh interval, `files.<name>.data.<key>.remoteRef`). Here a key maps straight to its source (`KEY: /path`) instead of a `remoteRef: {key, property}` block, and the store is implied by the block.
- **Parameter Store path → env vars with `find` + `rewrite`**, as in [Cloud Posse's ESO component](https://docs.cloudposse.com/components/library/aws/eks/external-secrets-operator/) and ESO's [rewrite guide](https://external-secrets.io/latest/guides/datafrom-rewrite/). `fromPath` generates the `find` (with the `name.regexp` that ESO's Parameter Store provider requires) and the prefix-stripping `rewrite` for you.
- **A scoped IAM role per app.** Cloud Posse uses one ClusterSecretStore for the whole cluster. Here each app has its own namespaced SecretStores and IRSA role, following ESO's advice to give each store [fine-grained IAM access](https://external-secrets.io/latest/provider/aws-parameter-store/). One app can't read another's secrets.

## Advanced: full ESO resources

For anything the simple blocks don't cover, these blocks expose ESO resources almost verbatim. Each one is off until `enabled: true`, with entries under `items`.

| Block | Renders | Use it for |
|-------|---------|------------|
| `externalSecrets` | `ExternalSecret` | `target.template`, generators, `find` by tags, `creationPolicy`, … |
| `pushSecrets` | `PushSecret` | writing Kubernetes Secrets back to AWS |
| `secretStores` / `clusterSecretStores` | `SecretStore` / `ClusterSecretStore` | Vault and other providers |
| `serviceAccounts` | `ServiceAccount` | additional IRSA roles for your own stores |
| `clusterExternalSecrets` | `ClusterExternalSecret` | one secret fanned out to many namespaces |

`externalSecrets` and `pushSecrets` items can use the AWS stores with `source: parameterStore` / `source: secretsManager`. Without `source` or `secretStoreRef`, they use `defaults.secretStoreRef`, then the Secrets Manager store (or Parameter Store if only that is enabled):

```yaml
secrets:
  aws: {roleArn: "arn:aws:iam::123456789012:role/my-cluster-my-app-secrets", region: eu-west-1}
  parameterStore:
    enabled: true                # creates the store; simple entries are optional
  externalSecrets:
    enabled: true
    items:
      my-app-dsn:
        source: parameterStore
        target:
          template:
            data:
              DATABASE_URL: "postgres://{{ .user }}:{{ .pass }}@{{ .host }}:5432/app"
        data:
          - secretKey: user
            remoteRef: {key: /my-app/db/user}
          - secretKey: pass
            remoteRef: {key: /my-app/db/pass}
          - secretKey: host
            remoteRef: {key: /my-app/db/host}
```

**A store that already exists in the cluster** (no IAM role from this chart):

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

**HashiCorp Vault or another provider:**

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

PushSecrets need write permissions on the role (`ssm:PutParameter`/`AddTagsToResource`, or `secretsmanager:CreateSecret`/`PutSecretValue`/`TagResource`). Cluster-scoped resources need a Helm release identity that's allowed to create them.

## Upgrading

**From 0.4.**
- **Store names:** the AWS stores are now `<release>-parameter-store` and `<release>-secrets-manager`, not `aws-parameter-store` and `aws-secrets-manager`, so two apps can share a namespace. Helm replaces the stores on upgrade and the ExternalSecrets follow; ESO re-syncs on its next refresh and the existing Kubernetes Secrets stay in place. If an advanced item references a store as `secretStoreRef: {name: aws-parameter-store}`, switch it to `source: parameterStore`.
- **Terraform role name:** the default is now `<cluster_name>-<app>-secrets`. To keep a role created with 0.4, set `role_name = "<app>-secrets"`; otherwise Terraform replaces it and you update `aws.roleArn`.

**From 0.3.** `aws.enabled`, `aws.secretsManager`, `aws.parameterStore` and `aws.defaultSource` are gone. Enabling `parameterStore` or `secretsManager` creates the store and ServiceAccount. You can move simple `externalSecrets.items` into those blocks or leave them where they are (`source:` still works):

```yaml
# 0.3                                   # 0.4
aws:                                    aws:
  enabled: true                           roleArn: arn:...
  roleArn: arn:...                        region: eu-west-1
  region: eu-west-1                     parameterStore:
  parameterStore: {enabled: true}         enabled: true
externalSecrets:                          secrets:
  enabled: true                             my-app-config:
  items:                                      LOG_LEVEL: /my-app/log-level
    my-app-config:
      source: parameterStore
      data:
        - secretKey: LOG_LEVEL
          remoteRef: {key: /my-app/log-level}
```

Fix any `dataFrom.find` over Parameter Store that has only a `path`. ESO needs `name: {regexp: ".*"}` as well, and a `rewrite` to strip the path, because `/` isn't allowed in Secret keys. Or switch to `fromPath`, which does both.

**From 0.2.** Wrap every collection in `enabled: true` + `items:`. The old layout fails the schema check, so nothing is silently dropped.

## Values reference

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Master switch. `false` renders nothing. |
| `aws.roleArn` | `""` | The app's IAM role ARN (templatable). Required when `parameterStore` or `secretsManager` is enabled. |
| `aws.region` | `""` | AWS region. Required likewise. |
| `aws.serviceAccountName` | `<release>-secrets` | Exact ServiceAccount name (templatable, no `namePrefix`). Must match the role's trust policy. |
| `aws.serviceAccountAnnotations` | `{}` | Extra ServiceAccount annotations. |
| `parameterStore.enabled` | `false` | Render SecretStore `<release>-parameter-store` and `parameterStore.secrets`. |
| `parameterStore.refreshInterval` | `defaults.refreshInterval` | For every entry of the block. |
| `parameterStore.secrets` | `{}` | Kubernetes Secrets to build; see [step 3](#3-list-the-apps-secrets). |
| `secretsManager.enabled` | `false` | Render SecretStore `<release>-secrets-manager` and `secretsManager.secrets`. |
| `secretsManager.refreshInterval` | `defaults.refreshInterval` | For every entry of the block. |
| `secretsManager.secrets` | `{}` | Kubernetes Secrets to build; see [step 3](#3-list-the-apps-secrets). |
| `apiVersion` | `external-secrets.io/v1` | API version for stores, ExternalSecret and ClusterExternalSecret. |
| `pushSecretApiVersion` | `external-secrets.io/v1alpha1` | API version for PushSecret. |
| `namePrefix` | `""` | Prefix for every resource name except the aws ServiceAccount. Rendered with `tpl`, e.g. `"{{ .Release.Name }}-"`. |
| `commonLabels` / `commonAnnotations` | `{}` | Added to every resource (an item's own `labels`/`annotations` win on conflict). |
| `defaults.refreshInterval` | `1h` | Default refresh interval. |
| `defaults.secretStoreRef` | `{name: "", kind: SecretStore}` | Default store for advanced items. When the name is empty, the Secrets Manager store is used (or Parameter Store if only that is enabled). |
| `defaults.target` | `{creationPolicy: Owner, deletionPolicy: Retain}` | ExternalSecret target defaults. |
| `<advanced block>.enabled` / `.items` | `false` / `{}` | See [Advanced](#advanced-full-eso-resources). |

### Advanced item fields

Every item accepts `enabled` (default `true`), `labels` and `annotations`. Namespaced kinds also accept `namespace` (default: the release namespace).

| Block | Item fields |
|-------|-------------|
| `externalSecrets.items.<name>` | `data` and/or `dataFrom` **(at least one required)**, `source` (`parameterStore`/`secretsManager`) or `secretStoreRef`, `refreshInterval`, `refreshPolicy`, `target` (merged over `defaults.target`; `target.name` defaults to the resource name) |
| `pushSecrets.items.<name>` | `selector` and `data` **(required)**, `source` or `secretStoreRefs` (each by `name`/`kind` or by `labelSelector`; default: the default store), `refreshInterval`, `updatePolicy`, `deletionPolicy` |
| `serviceAccounts.items.<name>` | `roleArn` (IAM role ARN, templatable). Rendered with `automountServiceAccountToken: false`. |
| `secretStores.items.<name>`, `clusterSecretStores.items.<name>` | `provider` **(required)**, `extraSpec` (other spec fields such as `retrySettings`, `refreshInterval`, `conditions`; merged into `spec`, must not contain `provider`) |
| `clusterExternalSecrets.items.<name>` | `externalSecretSpec` **(required, full ExternalSecret spec, verbatim except `secretStoreRef`, which is resolved like an ExternalSecret's but never falls back to the namespaced AWS stores)**, `externalSecretName`, `namespaceSelectors`, `namespaces`, `refreshTime` |

## Behaviour notes

- **Opt-in features.** Nothing renders until its block has `enabled: true`. Referencing a store or ServiceAccount whose block is off fails rendering instead of producing a dangling reference.
- **IAM roles only.** For any store with an `aws` provider, static keys (`auth.secretRef`) are rejected. In the advanced blocks, when `auth.jwt.serviceAccountRef.name` matches an entry in `serviceAccounts.items`, that entry must set `roleArn`, must be in the same namespace as a `SecretStore`, and the reference gets `namePrefix` (plus `namespace` for a `ClusterSecretStore`).
- **ESO templates vs Helm templates.** `target.template` and `externalSecretSpec` are **not** run through Helm's `tpl`, so ESO's `{{ .key }}` syntax works as written. `namePrefix`, `secretStoreRef.name`, `aws.roleArn`, `aws.serviceAccountName`, store `provider` and `extraSpec` **are** rendered with `tpl`.
- **Names that are unique per release.** The ServiceAccount (`<release>-secrets`) and the AWS stores (`<release>-parameter-store`, `<release>-secrets-manager`) include the release name and ignore `namePrefix`, so several apps can share a namespace. The ExternalSecrets and Kubernetes Secrets use your entry names (plus `namePrefix`), so pick names that are unique within the namespace.
- **Name prefix and references.** When a `secretStoreRef.name` matches a store defined in this chart, the reference is rewritten to that store's rendered name (`namePrefix` for advanced stores, the exact name for the AWS stores). References to stores defined elsewhere are used exactly as written. For the AWS stores, prefer `source: parameterStore` / `source: secretsManager`.
- **Disabling refresh.** `refreshInterval: 0` is kept as is, so ESO fetches once and never refreshes. It does not fall back to the default.
- **Schema.** `values.schema.json` checks types and rejects unknown keys and invalid Secret key names, so `enabled: "true"`, `BAD/KEY:`, an unknown `source`, a malformed `roleArn` or an old layout fails at `helm install`/`template`/`lint` time. In `parameterStore`/`secretsManager` entries any valid key name is a Secret key, so a misspelt `fromPath` becomes a key and then fails because its value isn't a parameter name.
- **Validation.** Rendering fails with an `external-secrets-subchart: …` message for missing or conflicting settings. `helm lint` only reports these as `[INFO]`; use `helm template` to see them as errors.
- **Argo CD ordering.** To have stores sync before the ExternalSecrets that use them, add `argocd.argoproj.io/sync-wave: "-1"` to the stores' annotations (advanced blocks) or to `commonAnnotations`, overriding it per item.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Nothing renders | The block isn't enabled. Set `parameterStore.enabled: true` / `secretsManager.enabled: true` (or the advanced block's `enabled`). |
| Schema error after upgrading | Values use an older layout; see [Upgrading](#upgrading). |
| `no matches for kind "ExternalSecret" in version "external-secrets.io/v1"` | ESO isn't installed, or is older than 0.17. Install or upgrade ESO. (On a very old operator you can set `apiVersion: external-secrets.io/v1beta1`; ESO 2.x no longer serves it.) |
| `SecretStore "…" exists and cannot be imported into the current release` | Two releases render the same resource name in one namespace. Since 0.5 the AWS stores and ServiceAccount include the release name; for ExternalSecrets, rename one of the entries. |
| Pods still see old values | ESO updated the Secret but the pods haven't restarted; see [Restart pods when secrets change](#restart-pods-when-secrets-change). |
| SecretStore not `Valid`: `WebIdentityErr` / `AccessDenied ... AssumeRoleWithWebIdentity` | The role's trust policy doesn't match the ServiceAccount. It must allow `system:serviceaccount:<namespace>:<name>` exactly as rendered (`<release>-secrets` by default) via the cluster's OIDC provider. Check `kubectl -n <ns> get sa <name> -o yaml` for the `eks.amazonaws.com/role-arn` annotation. |
| ExternalSecret `SecretSyncedError` with `AccessDeniedException` | The role can be assumed but can't read that parameter or secret: widen `parameter_path_prefixes` / `secret_name_prefixes`, or add `kms_key_arns` for a customer-managed KMS key. |
| `ParameterNotFound` / `ResourceNotFoundException` | Wrong name or region. Parameter names start with `/`; check `aws.region`. |
| `fromPath` Secret is empty | No parameters under that path in that region, or the path differs in case. `aws ssm get-parameters-by-path --path /my-app/flags --recursive` should list them. |
| Other `SecretSyncedError` | Check `kubectl describe externalsecret <name>`, which shows ESO's error from AWS. |
| `helm dependency update` returns 401/403/404 from ghcr.io | The version isn't published yet. Check the version in your `Chart.yaml` against the [releases](https://github.com/charalamposlamprou/external-secrets-subchart/releases). |
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

| Command | Checks | Needs |
|---------|--------|-------|
| `tests/run.sh` | Golden snapshots of rendered output, ~40 invalid-values cases, per-release name uniqueness (`--update` rewrites the goldens after an intended change) | Helm, bash |
| `tests/check-docs.sh` | Every `values.yaml` key is in the README's values reference | bash |
| `tests/validate-crds.sh v2.14.0` | Server-side dry-run of every fixture against that ESO release's CRDs | a throwaway cluster, e.g. `kind create cluster` |
| `tests/e2e.sh` | Real ESO + mock AWS ([moto](https://github.com/getmoto/moto)): IRSA token → STS → Parameter Store / Secrets Manager → Kubernetes Secrets, value changes, two releases in one namespace | a throwaway cluster |
| `cd examples/terraform/irsa-role && terraform init -backend=false && terraform test` | IAM role name, trust policy and permissions, planned without AWS access | Terraform ≥ 1.7 |
| `helm lint . --strict -f ci/full-values.yaml` | Chart structure | Helm |

The `lint` workflow runs all of them on every push and pull request: the Helm checks on Helm 3.16, 3.22 and 4.3, the CRD check against ESO 0.17.0 and 2.14.0, and the e2e test against ESO 2.14.0. `main` is protected, so a PR merges only when they pass. Workflow actions are pinned to commit SHAs and kept current by Dependabot.
