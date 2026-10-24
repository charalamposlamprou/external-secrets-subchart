# Plans the module without AWS access; IAM documents are rendered locally.
#   terraform init -backend=false && terraform test

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

variables {
  cluster_name  = "dev"
  app_role_arns = ["arn:aws:iam::123456789012:role/dev-my-app-secrets"]
}

run "controller_role" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "dev-external-secrets"
    error_message = "role name should default to <cluster>-external-secrets"
  }
  assert {
    condition     = jsondecode(data.aws_iam_policy_document.trust.json).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "the role must be assumable through EKS Pod Identity"
  }
  assert {
    condition     = toset(jsondecode(data.aws_iam_policy_document.trust.json).Statement[0].Action) == toset(["sts:AssumeRole", "sts:TagSession"])
    error_message = "Pod Identity needs sts:AssumeRole and sts:TagSession in the trust policy"
  }
  assert {
    condition     = jsondecode(data.aws_iam_policy_document.assume_app_roles.json).Statement[0].Resource == "arn:aws:iam::123456789012:role/dev-my-app-secrets"
    error_message = "the controller may only assume the listed app roles"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.namespace == "external-secrets" && aws_eks_pod_identity_association.this.service_account == "external-secrets" && aws_eks_pod_identity_association.this.cluster_name == "dev"
    error_message = "association must target the ESO controller's ServiceAccount"
  }
}

run "rejects_empty_app_roles" {
  command = plan
  variables {
    app_role_arns = []
  }
  expect_failures = [var.app_role_arns]
}
