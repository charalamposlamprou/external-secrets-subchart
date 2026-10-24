variable "cluster_name" {
  description = "EKS cluster name; its OIDC provider must already be registered in IAM."
  type        = string
}

variable "app" {
  description = "App name. Used for the role name and the default secret/parameter prefixes."
  type        = string
}

variable "namespace" {
  description = "Namespace the Helm release (and the subchart's ServiceAccount) lives in."
  type        = string
}

variable "service_account" {
  description = "Rendered ServiceAccount name (default: <app>-secrets, the chart's default when the release is named <app>)."
  type        = string
  default     = null
}

variable "secrets_manager" {
  description = "Allow reading Secrets Manager secrets (matches aws.secretsManager.enabled)."
  type        = bool
  default     = true
}

variable "secret_name_prefixes" {
  description = "Secrets Manager name prefixes the app may read (default: [\"<app>/\"])."
  type        = list(string)
  default     = null
}

variable "parameter_store" {
  description = "Allow reading SSM Parameter Store parameters (matches aws.parameterStore.enabled)."
  type        = bool
  default     = false
}

variable "parameter_path_prefixes" {
  description = "Parameter Store paths the app may read, with leading slash (default: [\"/<app>/\"])."
  type        = list(string)
  default     = null
}

variable "allow_find" {
  description = "Allow Secrets Manager dataFrom.find in advanced externalSecrets items (secretsmanager:ListSecrets, which can't be scoped). Not needed for parameterStore fromPath."
  type        = bool
  default     = false
}

variable "kms_key_arns" {
  description = "Customer-managed KMS keys encrypting the secrets or SecureString parameters. Leave empty for AWS-managed keys."
  type        = list(string)
  default     = []
}
