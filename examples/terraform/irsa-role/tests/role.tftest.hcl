# Plans the module without AWS access: the lookups are overridden, the provider never
# authenticates, and the IAM policy documents are rendered locally.
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

override_data {
  target = data.aws_eks_cluster.this
  values = { identity = [{ oidc = [{ issuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE" }] }] }
}
override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}
override_data {
  target = data.aws_partition.current
  values = { partition = "aws" }
}
override_data {
  target = data.aws_region.current
  values = { region = "eu-west-1" }
}

variables {
  cluster_name = "dev"
  app          = "my-app"
  namespace    = "my-app"
}

run "defaults_secrets_manager_only" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "dev-my-app-secrets"
    error_message = "role name should default to <cluster>-<app>-secrets"
  }
  assert {
    condition     = jsondecode(data.aws_iam_policy_document.trust.json).Statement[0].Condition.StringEquals["oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE:sub"] == "system:serviceaccount:my-app:my-app-secrets"
    error_message = "trust policy must allow only the chart's ServiceAccount"
  }
  assert {
    condition     = jsondecode(data.aws_iam_policy_document.trust.json).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
    error_message = "trust policy must name the cluster's OIDC provider"
  }
  assert {
    condition     = [for st in jsondecode(data.aws_iam_policy_document.read.json).Statement : st.Sid] == ["ReadAppSecrets"]
    error_message = "only Secrets Manager read access by default"
  }
  assert {
    condition     = one([for st in jsondecode(data.aws_iam_policy_document.read.json).Statement : st.Resource if st.Sid == "ReadAppSecrets"]) == "arn:aws:secretsmanager:eu-west-1:123456789012:secret:my-app/*"
    error_message = "Secrets Manager access must be scoped to the app prefix"
  }
}

run "parameter_store_find_kms_overrides" {
  command = plan

  variables {
    parameter_store         = true
    parameter_path_prefixes = ["/my-app/", "/shared"]
    allow_find              = true
    kms_key_arns            = ["arn:aws:kms:eu-west-1:123456789012:key/abc"]
    role_name               = "my-app-secrets"
    service_account         = "custom-sa"
    permissions_boundary    = "arn:aws:iam::123456789012:policy/boundary"
    tags                    = { team = "payments" }
  }

  assert {
    condition     = aws_iam_role.this.name == "my-app-secrets" && aws_iam_role.this.permissions_boundary == "arn:aws:iam::123456789012:policy/boundary" && aws_iam_role.this.tags["team"] == "payments"
    error_message = "role_name, permissions_boundary and tags must be applied"
  }
  assert {
    condition     = jsondecode(data.aws_iam_policy_document.trust.json).Statement[0].Condition.StringEquals["oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE:sub"] == "system:serviceaccount:my-app:custom-sa"
    error_message = "service_account override must reach the trust policy"
  }
  assert {
    condition = toset(one([for st in jsondecode(data.aws_iam_policy_document.read.json).Statement : st.Resource if st.Sid == "ReadAppParameters"])) == toset([
      "arn:aws:ssm:eu-west-1:123456789012:parameter/my-app",
      "arn:aws:ssm:eu-west-1:123456789012:parameter/my-app/*",
      "arn:aws:ssm:eu-west-1:123456789012:parameter/shared",
      "arn:aws:ssm:eu-west-1:123456789012:parameter/shared/*",
    ])
    error_message = "Parameter Store access must cover each path and everything under it"
  }
  assert {
    condition     = one([for st in jsondecode(data.aws_iam_policy_document.read.json).Statement : st.Action if st.Sid == "FindAppSecrets"]) == "secretsmanager:ListSecrets"
    error_message = "allow_find should add only secretsmanager:ListSecrets"
  }
  assert {
    condition = toset(one([for st in jsondecode(data.aws_iam_policy_document.read.json).Statement : st.Condition.StringEquals["kms:ViaService"] if st.Sid == "DecryptAppSecrets"])) == toset([
      "secretsmanager.eu-west-1.amazonaws.com", "ssm.eu-west-1.amazonaws.com",
    ])
    error_message = "KMS decrypt must be limited to the enabled services"
  }
}

run "rejects_no_service" {
  command = plan
  variables {
    secrets_manager = false
    parameter_store = false
  }
  expect_failures = [aws_iam_role.this]
}

run "rejects_long_role_name" {
  command = plan
  variables {
    cluster_name = "a-very-long-cluster-name-for-production-workloads-eu" # 67 chars with suffix
  }
  expect_failures = [aws_iam_role.this]
}
