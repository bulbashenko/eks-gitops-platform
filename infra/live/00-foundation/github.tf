# Three CI roles, least privilege by workflow stage:
#   ecr-push  - image builds on main only
#   tf-plan   - read-only plans on pull requests and main
#   tf-apply  - admin, but only from jobs bound to the protected `platform` GitHub Environment,
#               which requires a manual approval (see ADR-0004 for the trade-off)

data "aws_iam_policy_document" "ecr_push" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ecr.${var.region}.amazonaws.com"]
    }
  }
}

# ReadOnlyAccess covers the refresh; plans still need to take the state lock.
data "aws_iam_policy_document" "tf_plan" {
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*.tflock"]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*"]
  }
  statement {
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  repository      = var.github_repository
  subject_prefix  = var.github_oidc_subject_prefix
  create_provider = var.create_github_oidc_provider

  roles = {
    "${var.project}-gha-ecr-push" = {
      description = "GitHub Actions: build and push images from main"
      subjects    = ["ref:refs/heads/main"]
    }
    "${var.project}-gha-tf-plan" = {
      description         = "GitHub Actions: terraform plan (read-only)"
      subjects            = ["pull_request", "ref:refs/heads/main"]
      managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
    "${var.project}-gha-tf-apply" = {
      description          = "GitHub Actions: terraform apply/destroy via the approved platform environment"
      subjects             = ["environment:platform"]
      managed_policy_arns  = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      max_session_duration = 7200
    }
  }

  inline_policies = {
    "${var.project}-gha-ecr-push" = data.aws_iam_policy_document.ecr_push.json
    "${var.project}-gha-tf-plan"  = data.aws_iam_policy_document.tf_plan.json
  }
}
