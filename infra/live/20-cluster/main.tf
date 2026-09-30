# EPHEMERAL layer: the EKS cluster and everything Argo CD needs to take over.
# Terraform owns AWS-side resources (cluster, IAM, Pod Identity, Karpenter queue) and installs
# only Argo CD. Every in-cluster add-on is then delivered by Argo CD from gitops/.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
  backend "s3" {
    key = "20-cluster/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Layer       = "20-cluster"
  }

  foundation = data.terraform_remote_state.foundation.outputs
  network    = data.terraform_remote_state.network.outputs
}

data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${local.account_id}"
    key    = "00-foundation/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${local.account_id}"
    key    = "10-network/terraform.tfstate"
    region = var.region
  }
}
