# The ESO controller's own role for the chart's aws.auth: podIdentity. EKS Pod Identity gives
# it to the controller pod; the controller then assumes each app's role (with session tags) to
# read that app's secrets. It has no access to secrets itself.

locals {
  role_name = coalesce(var.role_name, "${var.cluster_name}-external-secrets")
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "assume_app_roles" {
  statement {
    sid       = "AssumeAppRoles"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = var.app_role_arns
  }
}

resource "aws_iam_role" "this" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = var.permissions_boundary
  tags                 = var.tags

  lifecycle {
    precondition {
      condition     = length(local.role_name) <= 64
      error_message = "IAM role names are at most 64 characters; set role_name."
    }
  }
}

resource "aws_iam_role_policy" "assume_app_roles" {
  name   = "assume-app-roles"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.assume_app_roles.json
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
  tags            = var.tags
}
