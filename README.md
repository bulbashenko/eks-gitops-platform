# eks-gitops-platform

A production-style platform for containerised microservices on AWS: **EKS + Karpenter**, layered **Terraform**,
**GitHub Actions** with OIDC, **Argo CD** GitOps, **Argo Rollouts** canaries gated by Prometheus,
**Kyverno** admission policies, and Prometheus / Grafana / Loki observability.

The environment is **ephemeral by design**: one command builds it in about 30 minutes, and one command removes it without leaving orphans.
Only a small persistent layer (state, registries, DNS, certificate) survives between runs. It costs about $0.30/h while up.

| Read | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How it fits together, with diagrams |
| [docs/adr/](docs/adr/README.md) | 11 decision records: what was chosen, the trade-offs, the rejected alternatives |
| [docs/demo-script.md](docs/demo-script.md) | Live demo: canary auto-rollback, Karpenter scale-out, policy enforcement |
| [docs/runbooks/](docs/runbooks/README.md) | Symptom-first operational procedures |

## Repository layout

| Path | What |
|---|---|
| `apps/` | Go services: `api` (HTTP → SQS), `worker` (SQS → Postgres + S3), `loadgen` (synthetic traffic). One multi-arch Dockerfile |
| `local/` | Docker Compose stack (Postgres + ElasticMQ) to run the services without AWS |
| `infra/bootstrap/` | One-time: S3 state bucket + KMS key (the only local-state stack) |
| `infra/live/00-foundation/` | **Persistent:** GitHub OIDC roles, ECR, Route 53 zone, ACM certificate, budget |
| `infra/live/10-network/` | **Ephemeral:** 3-AZ VPC, NAT, S3 endpoint |
| `infra/live/20-cluster/` | **Ephemeral:** EKS, system node group, Karpenter, Pod Identity, Argo CD + GitOps Bridge |
| `infra/live/30-data/` | **Ephemeral:** RDS PostgreSQL, SQS + DLQ, S3, per-service Pod Identity |
| `gitops/bootstrap/` | What the Argo CD root app syncs: AppProjects and ApplicationSets |
| `gitops/platform/` | Platform config: Karpenter NodePools, Kyverno policies, secret store, dashboards, SLO rules |
| `gitops/charts/service/` | Shared chart: Rollout/Deployment, ALB canary, analysis, HPA, PDB, NetworkPolicy, ExternalSecret |
| `gitops/apps/<service>/` | Per-service values. CI bumps `image.tag` here |
| `.github/workflows/` | `app-ci`, `terraform` (PR plans), `platform` (approved up/down) |
| `scripts/platform-down.sh` | Controller-aware teardown |

## The application

```
client ─POST /orders─▶ api ─▶ SQS orders (DLQ after 5 tries) ─▶ worker ─▶ RDS Postgres
       ◀─GET /orders/{id}─┘                                           └─▶ S3 receipts/
```

- `/healthz`, `/readyz` (fails during shutdown so the ALB drains first) and `/metrics` (RED) on every service.
- Messages are deleted only after successful processing, and inserts are idempotent, so at-least-once delivery is safe.
- `FAULT_RATE=0.3` makes 30% of api requests fail. This produces the "bad release" for the canary demo.
- `GET /burn?ms=50` burns CPU so load tests drive the HPA and Karpenter.

```bash
make test
make local-up
curl -s -XPOST localhost:8080/orders -d '{"item":"coffee","qty":2}'   # {"id":"…","status":"queued"}
curl -s localhost:8080/orders/<id>
make local-down
```

## Bootstrap a new AWS account (one time)

Prerequisites: an AWS CLI session with admin rights in the target account, plus `terraform`, `kubectl`, `helm`, `go`, `docker` (with buildx) and `pre-commit`.

```bash
# 1. State bucket + KMS key
make bootstrap

# 2. DNS zone first: the certificate cannot validate until the zone is delegated
export TF_VAR_budget_email=you@example.com
make init-00-foundation
terraform -chdir=infra/live/00-foundation apply -target=aws_route53_zone.demo
terraform -chdir=infra/live/00-foundation output name_servers
```

3. **Delegate the subdomain.** At dns.he.net → `bulbashenko.com` → *New NS*, set the name to `demo.bulbashenko.com` and add one record for each of the 4 name servers.
   Check it with `dig NS demo.bulbashenko.com +short`.

```bash
# 4. The rest of the foundation (ECR, ACM, CI roles, budget)
make apply-00-foundation
terraform -chdir=infra/live/00-foundation output github_role_arns
```

5. **GitHub settings** (*Settings → Secrets and variables → Actions*):

| Kind | Name | Value |
|---|---|---|
| Variable | `AWS_ROLE_ECR_PUSH` / `AWS_ROLE_TF_PLAN` / `AWS_ROLE_TF_APPLY` | from the output above |
| Variable | `CLUSTER_ADMIN_ARNS` | JSON list of IAM role ARNs that get cluster-admin. For IAM Identity Center roles use the **full ARN including the path** (`…:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_…`); EKS rejects the path-less form. Find it with `aws iam list-roles --path-prefix /aws-reserved/` |
| Variable | `UI_ALLOWED_CIDRS` | JSON list used by PR plans, e.g. `["203.0.113.7/32"]` |
| Secret | `BUDGET_EMAIL` | budget alert address (used by foundation plans) |

   Then create an **Environment** named `platform` with yourself as a required reviewer. Only jobs in it can assume the apply role.

6. Push to `main`, which makes `app-ci` build and publish the first images.

## Day-to-day

```bash
# From GitHub: Actions → platform → Run workflow → up (enter your IP/32) … later → down

# Or locally (your own ARN must be in cluster_admin_arns so Terraform can reach the cluster):
export TF_VAR_ui_allowed_cidrs="[\"$(curl -s ifconfig.me)/32\"]"
export TF_VAR_cluster_admin_arns='["arn:aws:iam::<account>:role/<your-admin-role>"]'
make up      # network → cluster → data  (~30 min, then ~10 min for Argo CD to converge)
make down    # pause Argo CD → remove ALBs and Karpenter nodes → destroy data → cluster → network
make help
```

## Quality gates

`pre-commit` runs locally and CI runs the same checks: `terraform fmt/validate`, `tflint` (AWS ruleset), `checkov` (every skip is justified), `gofmt`, `go vet`, unit tests, Trivy image scan, and `actionlint`-clean workflows with third-party actions pinned by commit SHA.
