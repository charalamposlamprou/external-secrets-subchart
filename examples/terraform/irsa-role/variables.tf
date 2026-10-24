variable "cluster_name" {
  description = "EKS cluster name; its OIDC provider must already be registered in IAM."
  type        = string
}

variable "app" {
  description = "App name. Used for the role name and, by default, the secret path prefix."
  type        = string
}

variable "namespace" {
  description = "Namespace the Helm release (and the subchart's ServiceAccount) lives in."
  type        = string
}

variable "service_account" {
  description = "Rendered ServiceAccount name, including any namePrefix (default: <app>-secrets)."
  type        = string
  default     = null
}

variable "secret_name_prefixes" {
  description = "Secrets Manager name prefixes the app may read (default: [\"<app>/\"])."
  type        = list(string)
  default     = null
}

variable "kms_key_arns" {
  description = "Customer-managed KMS keys encrypting those secrets. Leave empty for the AWS-managed key."
  type        = list(string)
  default     = []
}
