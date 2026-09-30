# EPHEMERAL layer: application data services and the application's AWS identities.
#   RDS PostgreSQL - master password generated and rotated by RDS in Secrets Manager
#   SQS            - orders queue + DLQ (5 attempts)
#   S3             - receipts bucket
# Outputs reach Argo CD through the GitOps Bridge annotations (see 20-cluster/argocd.tf).

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
  backend "s3" {
    key = "30-data/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "30-data"
    }
  }
}

provider "kubernetes" {
  host                   = local.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", var.region]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  network    = data.terraform_remote_state.network.outputs
  cluster    = data.terraform_remote_state.cluster.outputs
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${local.account_id}"
    key    = "10-network/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${local.account_id}"
    key    = "20-cluster/terraform.tfstate"
    region = var.region
  }
}

#------------------------------------------------------------------------------
# PostgreSQL
#------------------------------------------------------------------------------

resource "aws_security_group" "db" {
  # checkov:skip=CKV2_AWS_5: attached to the RDS instance through module.db
  name        = "${local.name}-db"
  description = "PostgreSQL, reachable only from EKS nodes and pods"
  vpc_id      = local.network.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from EKS nodes/pods"
  referenced_security_group_id = local.cluster.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.2"

  identifier = "${local.name}-orders"

  engine               = "postgres"
  engine_version       = var.postgres_major_version
  family               = "postgres${var.postgres_major_version}"
  major_engine_version = var.postgres_major_version
  instance_class       = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_encrypted     = true

  db_name  = "orders"
  username = "orders_admin"
  port     = 5432

  # RDS generates the password and stores it in Secrets Manager; Terraform never sees it.
  manage_master_user_password = true

  multi_az               = var.multi_az
  db_subnet_group_name   = local.network.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]

  create_db_option_group = false
  parameters = [
    { name = "rds.force_ssl", value = "1" },
    { name = "log_min_duration_statement", value = "500" },
  ]

  # Ephemeral environment: no final snapshot, no deletion protection (ADR-0011).
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

#------------------------------------------------------------------------------
# Queue + receipts bucket
#------------------------------------------------------------------------------

module "orders_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  name                       = "${local.name}-orders"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  sqs_managed_sse_enabled    = true

  create_dlq                    = true
  dlq_message_retention_seconds = 1209600
  redrive_policy = {
    maxReceiveCount = 5
  }
}

module "receipts" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.16.1"

  bucket_prefix = "${local.name}-receipts-"
  force_destroy = true

  control_object_ownership              = true
  object_ownership                      = "BucketOwnerEnforced"
  attach_deny_insecure_transport_policy = true

  versioning = { enabled = false }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = { sse_algorithm = "AES256" }
    }
  }

  lifecycle_rule = [{
    id         = "expire-receipts"
    enabled    = true
    filter     = {}
    expiration = { days = 30 }
  }]
}
