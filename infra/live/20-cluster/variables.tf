variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "project" {
  type    = string
  default = "egp"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "system_instance_type" {
  description = "Graviton instance for the system node group."
  type        = string
  default     = "t4g.medium"
}

variable "max_pods" {
  description = "kubelet maxPods for system nodes; relies on VPC CNI prefix delegation."
  type        = number
  default     = 58
}

variable "cluster_admin_arns" {
  description = "IAM principals (besides the CI apply role) that get cluster-admin, e.g. your SSO role."
  type        = list(string)
  default     = []
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ui_allowed_cidrs" {
  description = "Source CIDRs allowed to reach argocd., grafana. and rollouts. through the ALB."
  type        = list(string)
}

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/bulbashenko/eks-gitops-platform.git"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}
