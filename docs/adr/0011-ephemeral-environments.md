# ADR-0011: Ephemeral environments and the cost model

**Status:** Accepted

## Context
The project must run for the price of AWS promotional credits. An always-on EKS environment costs roughly $200+/month.

## Decision
- The environment is **ephemeral**: `make up` (or the `platform` workflow) builds network → cluster → data in about 30 minutes, and `make down` removes it.
- Anything that must survive, or is slow or manual to recreate (ECR images, DNS zone delegation, ACM certificate, CI roles), lives in the persistent `00-foundation` layer.
- Demo-grade settings sit behind flags: single NAT, single-AZ RDS (`multi_az`), no RDS final snapshot or deletion protection, no persistent volumes, single replicas of controllers.
- A monthly **AWS Budget** alerts at 50/80/100% of $10 (measured without credits), plus a forecast alert.
- Teardown is **controller-aware** (`scripts/platform-down.sh`). It pauses Argo CD, deletes Ingresses and NodePools so the LB controller and Karpenter remove the ALB and EC2 instances they created, waits for them to go, then destroys the layers in reverse order.

## Cost while running (eu-central-1, approximate)

| Item | $/hour |
|---|---|
| EKS control plane | 0.100 |
| 2 × t4g.medium (system) | 0.067 |
| NAT gateway (+ small data) | 0.050 |
| ALB | 0.030 |
| RDS db.t4g.micro | 0.018 |
| Karpenter Spot nodes (typ. 1–2 small) | 0.010–0.030 |
| Public IPv4, KMS, Secrets, CloudWatch logs | ~0.020 |
| **Total** | **≈ 0.30** (≈ $7/day) |

Persistent layer when down: under $2/month (Route 53 zone $0.50, KMS keys, ECR storage).

## Consequences
- A realistic platform for the price of a few coffees per demo day.
- The first sync after `up` takes about 10 minutes, so demos must start the environment ahead of time.
- Data does not survive `down`. That is by design, and a production environment would flip the flags above and keep backups.
