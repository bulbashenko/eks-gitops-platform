# Architecture Decision Records

Each record captures one decision: the context, what was chosen, what it costs, and what was rejected.
Format: [Michael Nygard's ADR template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

| # | Decision | Status |
|---|---|---|
| [0001](0001-eks.md) | Amazon EKS as the container platform | Accepted |
| [0002](0002-karpenter.md) | Karpenter for workload capacity, a small node group for controllers | Accepted |
| [0003](0003-single-nat.md) | One NAT gateway in the demo environment | Accepted |
| [0004](0004-terraform-layering.md) | Layered Terraform with isolated state and community modules | Accepted |
| [0005](0005-gitops-argocd.md) | Pull-based GitOps with Argo CD and a GitOps Bridge | Accepted |
| [0006](0006-pod-identity.md) | EKS Pod Identity instead of IRSA | Accepted |
| [0007](0007-secrets.md) | Secrets Manager + External Secrets Operator | Accepted |
| [0008](0008-progressive-delivery.md) | Canary releases with Argo Rollouts on the ALB | Accepted |
| [0009](0009-observability.md) | In-cluster Prometheus/Grafana/Loki | Accepted |
| [0010](0010-kyverno.md) | Kyverno for admission policy | Accepted |
| [0011](0011-ephemeral-environments.md) | Ephemeral environments and the cost model | Accepted |
