variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "project" {
  description = "Short prefix for resource names."
  type        = string
  default     = "egp"
}

variable "github_repository" {
  description = "owner/name of the repository whose workflows may assume the CI roles."
  type        = string
}

variable "github_oidc_subject_prefix" {
  description = "OIDC sub prefix incl. immutable owner/repo IDs: gh api repos/<owner>/<repo>/actions/oidc/customization/sub"
  type        = string
  default     = null
}

variable "create_github_oidc_provider" {
  description = "Only one GitHub OIDC provider can exist per account; set false to reuse an existing one."
  type        = bool
  default     = true
}

variable "services" {
  description = "Services that get an ECR repository."
  type        = list(string)
  default     = ["api", "worker", "loadgen"]
}

variable "domain" {
  description = "Subdomain delegated to Route 53 for the platform (api., argocd., grafana. live under it)."
  type        = string
}

variable "budget_limit_usd" {
  type    = number
  default = 10
}

variable "budget_email" {
  description = "Where budget alerts go. Pass via TF_VAR_budget_email; not committed."
  type        = string
}
