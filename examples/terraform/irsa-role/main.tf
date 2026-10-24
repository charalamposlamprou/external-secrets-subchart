# One IAM role per app, assumable only by that app's ESO ServiceAccount (IRSA),
# with read access to that app's secrets and/or parameters only.

locals {
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
  statement {
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
          # the path itself (GetParametersByPath) and everything under it
          "arn:${local.partition}:ssm:${local.region}:${local.account}:parameter${trimsuffix(p, "/")}",
          "arn:${local.partition}:ssm:${local.region}:${local.account}:parameter${trimsuffix(p, "/")}/*",
        ]
      ])
    }
  }

  dynamic "statement" {
    for_each = var.allow_find ? [1] : []
    content {
      sid = "FindAppSecrets"
      actions = concat(
        var.secrets_manager ? ["secretsmanager:ListSecrets"] : [],
        var.parameter_store ? ["ssm:DescribeParameters"] : [],
      )
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
  name               = "${var.app}-secrets"
  assume_role_policy = data.aws_iam_policy_document.trust.json

  lifecycle {
    precondition {
      condition     = var.secrets_manager || var.parameter_store
      error_message = "Enable at least one of secrets_manager or parameter_store."
    }
  }
}

resource "aws_iam_role_policy" "read" {
  name   = "read-secrets"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read.json
}
