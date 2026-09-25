locals {
  github_repo  = "muralidharan666666-dev/aws-three-tier-terraform"
  state_bucket = "murali-tfstate-9999"
  state_key    = "three-tier/terraform.tfstate"
  db_secret    = "three-tier/db/credentials"
}

data "aws_caller_identity" "current" {}

# Already exists in my account and another project uses it,
# so look it up instead of creating (or owning) it
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ------------------------------------------------------------
# PLAN ROLE - read-only. Used by pull requests, and by the
# plan that runs on main before I approve.
# ------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_repo}:pull_request",
        "repo:${local.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "github-terraform-plan"
  description        = "Read-only role for terraform plan in GitHub Actions"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess isn't quite enough for plan:
# 1. plan takes the state lock, so it must write and delete ONE lock file
# 2. plan refreshes the DB secret, so it must read that ONE secret
data "aws_iam_policy_document" "plan_extras" {
  statement {
    sid       = "StateLockFileOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/${local.state_key}.tflock"]
  }

  statement {
    sid       = "ReadDbSecretOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:us-east-1:${data.aws_caller_identity.current.account_id}:secret:${local.db_secret}-??????"]
  }
}

resource "aws_iam_role_policy" "plan_extras" {
  name   = "state-lock-and-db-secret"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_extras.json
}

# ------------------------------------------------------------
# APPLY ROLE - can change things. Only a job running in the
# "production" GitHub Environment can use it, and that
# environment needs my approval.
# ------------------------------------------------------------
data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "github-terraform-apply"
  description        = "Write role for terraform apply, production environment only"
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json
}

# Admin on purpose. The stack creates IAM roles, and anything that can
# create IAM roles can grant itself any permission anyway. The real
# control is WHO can assume this role - the trust policy above.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  #checkov:skip=CKV_AWS_274:The stack creates IAM roles, so a narrower policy would not really limit it. Only an approved production job can assume this role
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}