# PERSISTENT layer: everything that must survive `make down`, so an ephemeral
# environment can be recreated from scratch without manual steps:
# CI identity, container registries, the DNS zone and TLS certificate, and the cost guardrail.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
  backend "s3" {
    key = "00-foundation/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Layer     = "00-foundation"
    Repo      = var.github_repository
  }
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}"
}

#------------------------------------------------------------------------------
# Container registries
#------------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  for_each = toset(var.services)

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Drop untagged layers quickly"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 30 images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
        action       = { type = "expire" }
      },
    ]
  })
}

#------------------------------------------------------------------------------
# DNS + TLS. The zone is delegated from the parent domain's DNS (NS records),
# so validation only succeeds after delegation: see the README bootstrap steps.
#------------------------------------------------------------------------------

resource "aws_route53_zone" "demo" {
  name    = var.domain
  comment = "Delegated subdomain for the ${var.project} demo platform"
}

resource "aws_acm_certificate" "demo" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.demo.domain_validation_options : o.domain_name => o
  }

  zone_id         = aws_route53_zone.demo.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "demo" {
  certificate_arn         = aws_acm_certificate.demo.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

#------------------------------------------------------------------------------
# Cost guardrail
#------------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits would otherwise hide real spend: measure gross cost.
  cost_types {
    include_credit = false
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
