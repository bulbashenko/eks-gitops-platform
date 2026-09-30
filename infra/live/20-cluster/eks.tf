module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.26.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = local.network.vpc_id
  subnet_ids               = local.network.private_subnet_ids
  control_plane_subnet_ids = local.network.intra_subnet_ids

  # Public endpoint so GitHub-hosted runners and the presenter's laptop can reach the API;
  # authentication is IAM-only. Production would use a private endpoint plus
  # self-hosted runners inside the VPC (ADR-0001).
  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.access_entries

  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  addons = {
    vpc-cni = {
      before_compute = true
      # Prefix delegation: each ENI slot holds a /28, so small instances can run far more
      # than their default ~17 pods.
      # enableNetworkPolicy turns on the VPC CNI's eBPF NetworkPolicy agent.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    # Small, stable, on-demand group for platform controllers (Karpenter must not run on
    # capacity it manages). Application workloads land on Karpenter nodes.
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.system_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        "node-role.egp.io/system" = "true"
      }

      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: ${var.max_pods}
        EOT
      }]

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }
}

locals {
  admin_principals = merge(
    { ci = local.foundation.github_role_arns["${var.project}-gha-tf-apply"] },
    { for i, arn in var.cluster_admin_arns : "admin-${i}" => arn },
  )

  access_entries = merge(
    {
      for k, arn in local.admin_principals : k => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      # Pull-request plans refresh in-cluster resources managed by Terraform, including Helm
      # release Secrets, hence admin *view* (read incl. Secrets) rather than plain view.
      ci-plan = {
        principal_arn = local.foundation.github_role_arns["${var.project}-gha-tf-plan"]
        policy_associations = {
          view = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.26.0"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name}-karpenter-node"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
