output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}

output "oidc_audiences" {
  description = "Must include sts.amazonaws.com or GitHub can't log in"
  value       = data.aws_iam_openid_connect_provider.github.client_id_list
}