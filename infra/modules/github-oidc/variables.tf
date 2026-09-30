variable "repository" {
  description = "GitHub repository in owner/name form."
  type        = string
}

variable "create_provider" {
  description = "Create the account-wide GitHub OIDC provider. Set false if it already exists."
  type        = bool
  default     = true
}

variable "roles" {
  description = <<-EOT
    Roles to create, keyed by role name. `subjects` are OIDC sub claims relative to the repo,
    e.g. "ref:refs/heads/main", "pull_request", "environment:platform".
  EOT
  type = map(object({
    description          = string
    subjects             = list(string)
    managed_policy_arns  = optional(list(string), [])
    max_session_duration = optional(number, 3600)
  }))
}

variable "inline_policies" {
  description = "Inline policy JSON per role name. Keys must match keys of `roles`."
  type        = map(string)
  default     = {}
}
