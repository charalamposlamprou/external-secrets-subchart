output "role_arn" {
  description = "Pass as eso_controller_role_arn to each app's irsa-role module (trust including pod_identity)."
  value       = aws_iam_role.this.arn
}
