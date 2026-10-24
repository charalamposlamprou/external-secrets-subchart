variable "cluster_name" {
  description = "EKS cluster that runs External Secrets Operator. The EKS Pod Identity Agent add-on must be installed."
  type        = string
}

variable "namespace" {
  description = "Namespace of the ESO controller."
  type        = string
  default     = "external-secrets"
}

variable "service_account" {
  description = "ServiceAccount of the ESO controller (the ESO chart's default is external-secrets)."
  type        = string
  default     = "external-secrets"
}

variable "app_role_arns" {
  description = "App roles ESO may assume (the irsa-role module's role_arn with trust including pod_identity). A pattern such as arn:aws:iam::123456789012:role/*-secrets works too; each app role's trust policy still limits it to its namespace."
  type        = list(string)

  validation {
    condition     = length(var.app_role_arns) > 0
    error_message = "List at least one app role (or a pattern)."
  }
}

variable "role_name" {
  description = "IAM role name for the controller (default: <cluster_name>-external-secrets)."
  type        = string
  default     = null
}

variable "permissions_boundary" {
  description = "ARN of an IAM permissions boundary to attach to the role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for the IAM role and the Pod Identity association."
  type        = map(string)
  default     = {}
}
