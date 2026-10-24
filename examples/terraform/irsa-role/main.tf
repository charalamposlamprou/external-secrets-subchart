# One IAM role per app, with read access to that app's secrets and/or parameters only.
# Who may assume it depends on the chart's aws.auth (see `trust`):
#   irsa          the app's ESO ServiceAccount, through the cluster's OIDC provider
#   pod_identity  the ESO controller's Pod Identity role, only for ExternalSecrets in the app's
#                 namespace (checked through the esoNamespace session tag ESO sends)
# Trust both while moving an app from one to the other.

locals {
  role_name       = coalesce(var.role_name, "${var.cluster_name}-${var.app}-secrets")
  service_account = coalesce(var.service_account, "${var.app}-secrets")
  secret_prefixes = coalesce(var.secret_name_prefixes, ["${var.app}/"])
  param_prefixes  = coalesce(var.parameter_path_prefixes, ["/${var.app}/"])
  oidc_issuer     = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")

  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  account   = data.aws_caller_identity.current.account_id

  kms_services = concat(
    var.secrets_manager ? ["secretsmanager.${local.region}.amazonaws.com"] : [],
    var.parameter_store ? ["ssm.${local.region}.amazonaws.com"] : [],
  )
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "trust" {
  dynamic "statement" {
    for_each = contains(var.trust, "irsa") ? [1] : []
    content {
      sid     = "IRSA"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = ["arn:${local.partition}:iam::${local.account}:oidc-provider/${local.oidc_issuer}"]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.oidc_issuer}:sub"
        values   = ["system:serviceaccount:${var.namespace}:${local.service_account}"]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.oidc_issuer}:aud"
        values   = ["sts.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.trust, "pod_identity") ? [1] : []
    content {
      sid     = "PodIdentityViaESO"
      actions = ["sts:AssumeRole", "sts:TagSession"]
      principals {
        type = "AWS"
        # empty when unset, so the role's precondition reports the missing input
        identifiers = compact([var.eso_controller_role_arn])
      }
      # ESO tags every session with the namespace of the ExternalSecret it is syncing
      # (sessionTagsPolicy: Simple, set by the chart). Without this condition any namespace
      # could point a SecretStore at this role.
      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/esoNamespace"
        values   = [var.namespace]
      }
    }
  }
}

data "aws_iam_policy_document" "read" {
  dynamic "statement" {
    for_each = var.secrets_manager ? [1] : []
    content {
      sid     = "ReadAppSecrets"
      actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [
        for p in local.secret_prefixes :
        "arn:${local.partition}:secretsmanager:${local.region}:${local.account}:secret:${p}*"
      ]
    }
  }

  dynamic "statement" {
    for_each = var.parameter_store ? [1] : []
    content {
      sid     = "ReadAppParameters"
      actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      resources = flatten([
        for p in local.param_prefixes : [
          # the path itself (GetParametersByPath, used by fromPath) and everything under it
          "arn:${local.partition}:ssm:${local.region}:${local.account}:parameter${trimsuffix(p, "/")}",
          "arn:${local.partition}:ssm:${local.region}:${local.account}:parameter${trimsuffix(p, "/")}/*",
        ]
      ])
    }
  }

  # Parameter Store `fromPath` needs nothing extra: ESO lists a path with GetParametersByPath,
  # granted above on the same prefixes.
  dynamic "statement" {
    for_each = var.allow_find && var.secrets_manager ? [1] : []
    content {
      sid       = "FindAppSecrets"
      actions   = ["secretsmanager:ListSecrets"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "DecryptAppSecrets"
      actions   = ["kms:Decrypt"]
      resources = var.kms_key_arns
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = local.kms_services
      }
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags

  lifecycle {
    precondition {
      condition     = var.secrets_manager || var.parameter_store
      error_message = "Enable at least one of secrets_manager or parameter_store."
    }
    precondition {
      condition     = !contains(var.trust, "pod_identity") || var.eso_controller_role_arn != null
      error_message = "trust includes pod_identity: set eso_controller_role_arn (the eso-pod-identity module's role_arn)."
    }
    precondition {
      condition     = length(local.role_name) <= 64
      error_message = "IAM role names are at most 64 characters; set role_name."
    }
  }
}

resource "aws_iam_role_policy" "read" {
  name   = "read-secrets"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read.json
}
