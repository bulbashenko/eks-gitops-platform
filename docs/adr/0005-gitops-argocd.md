# ADR-0005: Pull-based GitOps with Argo CD and a GitOps Bridge

**Status:** Accepted

## Context
Delivering in-cluster components from CI (`helm upgrade` in a pipeline) gives CI cluster-admin credentials and leaves drift undetected. Terraform's Helm provider has the same problem, plus slow, fragile plans.

## Decision
- Terraform installs only **Argo CD** and a root app. Everything else is declared in `gitops/`: add-ons as one ApplicationSet each, apps generated per directory under `gitops/apps/`.
- **GitOps Bridge**: Terraform writes environment facts (cluster endpoint, queue URLs, role names, domain) as annotations on Argo CD's in-cluster Secret. ApplicationSets use the cluster generator to template them into Helm values. Each Terraform layer owns its keys through its own server-side-apply field manager.
- Two AppProjects: `platform` (cluster-wide) and `apps` (namespace `orders` only, no cluster-scoped kinds).
- CI deploys by committing an image tag to Git and never talks to the cluster.

## Consequences
- Git is the source of truth. Drift is visible and self-healed, and a rollback is a revert.
- No environment-specific values are committed, and the same `gitops/` tree works for any cluster that carries the annotations. That is the path to multi-cluster.
- Add-ons converge in dependency order through retries rather than strict ordering (for example, CRD-dependent apps retry until the CRDs exist). The first sync takes about 10 minutes.
- Argo CD becomes a critical component. Its UI is behind an IP allowlist, and production would add SSO.

## Alternatives considered
- **Flux**: equally capable. Argo CD was chosen for its UI (useful in demos and for app teams), ApplicationSets and native integration with Argo Rollouts.
- **Terraform helm_release for every add-on**: slow plans, drift only on apply, and CRD ordering issues.
- **Committing rendered values per environment**: duplicates Terraform outputs in Git and goes stale.
