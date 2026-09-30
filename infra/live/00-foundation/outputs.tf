output "name_servers" {
  description = "Add these as NS records for the subdomain at the parent domain's DNS provider."
  value       = aws_route53_zone.demo.name_servers
}

output "zone_id" {
  value = aws_route53_zone.demo.zone_id
}

output "domain" {
  value = var.domain
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.demo.certificate_arn
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_role_arns" {
  description = "Set these as GitHub repository variables (see README)."
  value       = module.github_oidc.role_arns
}
