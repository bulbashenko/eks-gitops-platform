# EPHEMERAL layer: VPC across three AZs.
#   public   /24 - ALB and the NAT gateway
#   private  /20 - EKS nodes and pods (VPC CNI gives pods VPC IPs, hence the larger range)
#   intra    /24 - EKS control-plane ENIs, no internet route
#   database /24 - RDS, no internet route

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
  backend "s3" {
    key = "10-network/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "10-network"
    }
  }
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = var.azs
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)]
  intra_subnets    = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 52 + i)]
  database_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 56 + i)]

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # The default security group is left with no rules at all.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter discovers the subnets for new nodes by this tag.
    "karpenter.sh/discovery" = local.name
  }
}

# S3 traffic (ECR image layers, receipts) bypasses the NAT gateway: free, and faster.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.database_route_table_ids)

  tags = {
    Name = "${local.name}-s3"
  }
}
