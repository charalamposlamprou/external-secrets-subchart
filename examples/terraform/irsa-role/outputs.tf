output "role_arn" {
  description = "Set as serviceAccounts.<name>.roleArn in the subchart values."
  value       = aws_iam_role.this.arn
}
