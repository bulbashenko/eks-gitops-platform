# GitHub Actions -> AWS federation. Workflows exchange their OIDC token for short-lived
# role credentials, so no AWS access keys are ever stored in GitHub.
# Each role is pinned to specific token subjects (branch, pull_request, environment).

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  subject_prefix = coalesce(var.subject_prefix, "repo:${var.repository}")
  provider_arn   = var.create_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
}

data "aws_iam_policy_document" "trust" {
  for_each = var.roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in each.value.subjects : "${local.subject_prefix}:${s}"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name                 = each.key
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  max_session_duration = each.value.max_session_duration
}

resource "aws_iam_role_policy_attachments_exclusive" "this" {
  for_each = var.roles

  role_name   = aws_iam_role.this[each.key].name
  policy_arns = each.value.managed_policy_arns
}

# Keyed by role name (known at plan time); the policy JSON may be unknown until apply.
resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = "inline"
  role   = aws_iam_role.this[each.key].id
  policy = each.value
}
