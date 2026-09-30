# ADR-0006: EKS Pod Identity instead of IRSA

**Status:** Accepted

## Context
Pods need AWS permissions (the LB controller, ExternalDNS, ESO, Karpenter, the apps). IRSA requires an OIDC provider per cluster, trust policies that embed the cluster's OIDC URL, and a role-ARN annotation on every service account.

## Decision
Use **EKS Pod Identity**. Terraform creates a role per workload and an association of (cluster, namespace, service account) → role. Helm values only name the service account.

## Consequences
- No role ARNs in Git, and roles are reusable across clusters (the trust policy is `pods.eks.amazonaws.com`, not a cluster-specific OIDC URL). Recreating the ephemeral cluster needs no trust-policy changes.
- Least privilege per service: the api can only `SendMessage`, the worker can only consume and write `receipts/*`, and ESO can only read `rds!*` and `egp/*` secrets.
- It needs the Pod Identity Agent add-on (installed before compute). IMDS is closed to pods (hop limit 1), so a misconfigured pod gets no credentials instead of the node role's.

## Alternatives considered
- **IRSA**: still required on non-EKS Kubernetes and for a few older SDKs. There is no reason to use it on a new EKS cluster.
- **Node-role permissions**: every pod on the node inherits everything. Rejected.
