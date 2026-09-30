# ADR-0007: Secrets Manager + External Secrets Operator

**Status:** Accepted

## Context
The apps need database credentials, and Grafana needs an admin password. Secrets must not live in Git, Terraform variables or Helm values.

## Decision
- RDS generates and rotates its master password (`manage_master_user_password`). Terraform never sees it.
- **External Secrets Operator** with one `ClusterSecretStore` (Pod Identity) syncs the RDS secret into Kubernetes. An ESO template builds libpq `PG*` variables for the apps.
- Credentials that only exist for the cluster's own use (the Grafana admin password) are generated **in-cluster** by an ESO `Password` generator, once (`refreshInterval: 0`). They never touch Terraform state, Secrets Manager or CI.

## Consequences
- Applications have no AWS permission to read secrets. Only ESO does, scoped to `rds!*` and `egp/*`.
- RDS rotation updates the Kubernetes Secret within `refreshInterval` (15 min), but running pods keep the old environment variables until restarted. Production would use Reloader or read credentials from a mounted file.
- Anything Terraform generates ends up in state, readable by every role that can plan. The first version generated the Grafana password with `random_password`: it sat in plain text in state, and the read-only CI plan role failed to refresh it (`GetSecretValue` denied). Generating it in-cluster removed the secret from Terraform entirely, and kept the plan role unable to read secrets.
- Apps currently connect as the master user. Production would create a least-privilege app role, or use IAM database authentication.

## Alternatives considered
- **Sealed Secrets / SOPS**: keeps encrypted secrets in Git, but brings key management and no rotation story.
- **Secrets Store CSI driver**: mounts secrets as files without creating Kubernetes Secrets. It is more secure, but it does not fit environment-variable based apps without the sync feature, which recreates Secrets anyway.
