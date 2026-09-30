# eks-gitops-platform

A production-style platform for containerised microservices on AWS: **EKS + Karpenter**, layered **Terraform**,
**GitHub Actions** with OIDC, **Argo CD** GitOps, **Argo Rollouts** canaries gated by Prometheus,
**Kyverno** policies, and a Prometheus/Grafana/Loki observability stack.

The environment is **ephemeral by design**: one command brings it up in about 30 minutes and one command removes it.
Only a small persistent layer (state, registries, DNS, certificate) survives between runs. See [docs/project-plan.md](docs/project-plan.md).

> Status: work in progress. Done so far: the application, local stack, state bootstrap and foundation layer.

## Repository layout

| Path | What |
|---|---|
| `apps/` | Go services: `api` (HTTP → SQS) and `worker` (SQS → Postgres + S3). One multi-arch Dockerfile |
| `local/` | Docker Compose stack (Postgres + ElasticMQ) for running the services without AWS |
| `infra/bootstrap/` | One-time stack: S3 state bucket + KMS key (the only local-state stack) |
| `infra/live/00-foundation/` | **Persistent:** GitHub OIDC roles, ECR, Route 53 zone, ACM certificate, budget alert |
| `infra/live/{10-network,20-cluster,30-data}/` | **Ephemeral:** VPC, EKS + Karpenter + Argo CD bootstrap, RDS/SQS/S3 |
| `infra/modules/` | Own modules (community `terraform-aws-modules` are used for VPC/EKS/RDS) |
| `gitops/` | Everything Argo CD syncs: platform add-ons and applications |
| `docs/` | Architecture, ADRs, runbooks, demo script |

## The application

```
client ──POST /orders──▶ api ──▶ SQS (orders, DLQ after 5 attempts) ──▶ worker ──▶ RDS Postgres
       ◀─GET /orders/{id}─┘                                                   └──▶ S3 receipts/
```

- Both services expose `/healthz`, `/readyz` (fails during shutdown so the ALB drains first) and `/metrics` (RED metrics).
- The worker deletes a message only after it is fully processed, and inserts are idempotent, so at-least-once delivery is safe.
- `FAULT_RATE=0.2` makes 20% of api requests fail. This produces the "bad release" that the canary analysis rolls back.
- `GET /burn?ms=50` burns CPU so a load test can drive the HPA and Karpenter.

Run it locally:

```bash
make test
make local-up
curl -s -XPOST localhost:8080/orders -d '{"item":"coffee","qty":2}'   # → {"id":"…","status":"queued"}
curl -s localhost:8080/orders/<id>
make local-down
```

## Bootstrap a new AWS account (one time)

Prerequisites: an AWS CLI profile with admin rights in a **fresh** account (`export AWS_PROFILE=…`),
and `terraform`, `kubectl`, `helm`, `go`, `docker` and `pre-commit` installed.

```bash
# 1. State bucket + KMS key
make bootstrap

# 2. Create the DNS zone first; the certificate cannot validate until the zone is delegated
export TF_VAR_budget_email=you@example.com
make init-00-foundation
terraform -chdir=infra/live/00-foundation apply -target=aws_route53_zone.demo
terraform -chdir=infra/live/00-foundation output name_servers
```

3. **Delegate the subdomain.** At dns.he.net, open `bulbashenko.com` → *New NS* → name `demo.bulbashenko.com`,
   and add one record for each of the 4 name servers from the output above.
   Check it with `dig NS demo.bulbashenko.com +short`.

```bash
# 4. Everything else in the foundation layer (ECR, ACM cert, CI roles, budget)
make apply-00-foundation
terraform -chdir=infra/live/00-foundation output github_role_arns
```

5. In GitHub → *Settings → Secrets and variables → Actions → Variables*, add `AWS_ROLE_ECR_PUSH`, `AWS_ROLE_TF_PLAN`
   and `AWS_ROLE_TF_APPLY` from that output. Then create an Environment named `platform` with required reviewers.

## Day-to-day

```bash
make up      # network → cluster → data  (≈ 30 min)
make down    # reverse order
make help    # all targets
```
