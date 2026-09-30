# ADR-0004: Layered Terraform with isolated state and community modules

**Status:** Accepted

## Context
One Terraform root for everything means slow plans, a huge blast radius per apply, and no way to keep some resources (registries, DNS) while destroying others.

## Decision
- **Root modules per layer**: `bootstrap` (local state) → `00-foundation` (persistent) → `10-network` → `20-cluster` → `30-data` (ephemeral). Each has its own state key in one S3 bucket with KMS encryption and native S3 locking (`use_lockfile`), so there is no DynamoDB table.
- Layers communicate only through outputs (`terraform_remote_state`).
- **terraform-aws-modules** (VPC, EKS, RDS, SQS, S3, Pod Identity) are pinned to exact versions. Our own small modules are used only where we add opinion (`github-oidc`).
- **CI roles**: PRs get a read-only plan role (`ReadOnlyAccess` + state lock). Apply uses an admin role that can only be assumed by jobs in the `platform` GitHub Environment, which requires reviewer approval.

## Consequences
- Plans run in seconds per layer, and a data-layer change cannot recreate the cluster.
- `make up` / `make down` operate only on ephemeral layers. The foundation's ECR images and certificate survive.
- Cross-layer dependencies are implicit contracts on output names, so renames need care.
- The apply role is admin. The mitigations are an OIDC subject pinned to a protected environment, required reviewers, and short sessions. In a multi-account setup it would carry a permissions boundary and only reach one account.

## Alternatives considered
- **Terragrunt**: good DRY and dependency handling, but one more tool to explain. Plain Terraform + Makefile is enough for four layers.
- **Writing VPC/EKS modules from scratch**: shows knowledge, but reinvents battle-tested code. An architect should compose, not rewrite.
- **Atlantis / HCP Terraform**: better PR workflows and locking UI. Sensible for a team, overkill here (roadmap).
