# Portfolio project: Production-grade AWS microservices platform

## Context

Target role: **DevOps Architect @ SNP Group**. The job asks for AWS, Terraform, containers/Kubernetes, CI/CD,
cloud security, observability, and strong architecture documentation.
The goal is one repo that proves hands-on skill **and** architectural judgement, shown as a live demo in AWS during the interview.

Constraints and decisions settled in the grilling session:
- **Time:** about 1 week for the core, with more time available after that.
- **Budget:** $0 of real money. Use a new AWS account on the Free Plan credits ($100 + up to $100).
  The environment is **ephemeral**: bring it up about 24h before the interview and destroy it after.
- **Workspace:** `~/Documents/devops-cloud` is empty; this is a greenfield project.
- **Docs language:** English.

## Decisions (each one gets an ADR)

| Area | Decision |
|---|---|
| Orchestrator | Amazon EKS |
| Compute | Small system managed node group (2× t4g.medium, on-demand) + **Karpenter** (Spot + Graviton) for workloads |
| Network | VPC across 3 AZs with public, private, and intra subnets. **One NAT Gateway** (`single_nat_gateway` flag; one NAT per AZ in prod). Free S3 gateway endpoint |
| Data | RDS PostgreSQL db.t4g.micro single-AZ (`multi_az` flag), SQS with a DLQ, S3 |
| App | 3 Go services: `api` → SQS → `worker` → RDS/S3 (+ `web`/status endpoint optional). Distroless, non-root, multi-arch images |
| IaC | Terraform. **Layered** root modules with separate states. `terraform-aws-modules` for VPC/EKS/RDS, own modules for glue |
| State | S3 backend with native locking (`use_lockfile`), KMS-encrypted |
| CI/CD | GitHub Actions in a **monorepo**, AWS access via OIDC (no static keys) |
| TF workflow | `plan` + tflint + checkov + Infracost comment on every PR. `platform-up` / `platform-down` via `workflow_dispatch` with Environment approval. `make up/down` as a local fallback |
| GitOps | Argo CD (app-of-apps), bootstrapped by Terraform |
| Delivery | **Argo Rollouts canary** with ALB traffic splitting and Prometheus AnalysisTemplate (auto-rollback on error rate) |
| Identity | **EKS Pod Identity**, with associations in Terraform so GitOps values need no role ARNs |
| Secrets | AWS Secrets Manager + External Secrets Operator |
| Ingress/DNS/TLS | AWS Load Balancer Controller, **one ALB** via IngressGroup, ACM certificate, ExternalDNS, delegated subdomain on Route53 |
| UI exposure | `api.` is public. `argocd.`, `grafana.`, `rollouts.` are behind a login plus an IP allowlist on the ALB |
| Observability | kube-prometheus-stack + Loki + Alloy. RED dashboards, SLO burn-rate alerts, CloudWatch datasource for RDS/SQS |
| Policy | Kyverno: disallow privileged pods, `:latest` tags, and missing limits; allow images from own ECR only |
| Supply chain (baseline) | Trivy image and IaC scans, checkov/tfsec, distroless images, KMS everywhere |

## Repo layout (`~/Documents/devops-cloud`)

```
apps/            api/ worker/ (Go, Dockerfile, /healthz, /readyz, /metrics, graceful shutdown)
infra/
  bootstrap/     ONE-TIME, local state: state bucket + KMS key
  modules/       github-oidc, pod-identity-app, platform-bootstrap (argocd helm + root app), app-resources (sqs/s3)
  live/
    00-foundation/   PERSISTENT: GitHub OIDC roles, ECR repos, Route53 subdomain zone, ACM cert, Budgets alert
    10-network/      EPHEMERAL: VPC, NAT, endpoints
    20-cluster/      EPHEMERAL: EKS, system NG, Karpenter (IAM + interruption SQS), addons, Pod Identity associations, ArgoCD bootstrap
    30-data/         EPHEMERAL: RDS, Secrets Manager secret, app SQS/S3
gitops/
  bootstrap/root-app.yaml
  platform/      lbc, external-dns, eso, karpenter-nodepools, kyverno(+policies), kube-prometheus-stack, loki, alloy, argo-rollouts
  apps/          api/ worker/ (Helm chart or Kustomize: Rollout, Service, Ingress, HPA, PDB, NetworkPolicy, ExternalSecret, ServiceMonitor)
.github/workflows/   app-ci.yml, tf-plan.yml, platform-up.yml, platform-down.yml
docs/
  architecture.md (+ diagram), adr/0001..0011, runbooks/, demo-script.md, cost.md
Makefile, .pre-commit-config.yaml, README.md
```

The persistent/ephemeral split is deliberate. ECR images, DNS, and the certificate survive `destroy`,
so each `up` takes about 25–30 min and needs no manual steps.

## Planned ADRs
1. EKS over ECS / EKS Auto Mode
2. Karpenter + system node group (vs Cluster Autoscaler, Fargate)
3. Single NAT in the demo env (cost vs AZ resilience)
4. Terraform layering, state isolation, community modules
5. Pull-based GitOps with Argo CD (vs push-based CI deploys, vs Flux)
6. EKS Pod Identity over IRSA
7. Secrets Manager + ESO
8. Progressive delivery: Argo Rollouts on ALB
9. In-cluster observability stack (vs AMP/AMG, CloudWatch Container Insights)
10. Kyverno over OPA Gatekeeper
11. Ephemeral environments and the cost model

## Live demo script (10–15 min, `docs/demo-script.md`)
0. Architecture diagram, then a 1-minute repo tour.
1. **Canary + auto-rollback:** push a "bad" version (env flag → 20% HTTP 500s). CI builds, scans, and pushes to ECR, then bumps the tag in `gitops/`. Argo CD syncs, the canary gets 20%, analysis fails, and the Rollout aborts on its own. Watch it in the Rollouts UI and Grafana.
2. **Scale-out:** a k6 load test → HPA → pending pods → Karpenter provisions a Graviton Spot node within ~1 min, visible in Grafana.
3. **Policy:** `kubectl apply` a privileged pod or a `:latest` image → Kyverno denies it.
4. Wrap-up: the cost table, and what changes for prod (NAT per AZ, Multi-AZ RDS, multiple accounts via Organizations, WAF, GuardDuty, cosign → roadmap).

## Milestones
- **Day 0 (prereqs):** new AWS account; confirm EKS is allowed on the Free Plan (if not, upgrade to paid, credits carry over); set a $10 Budgets alert; delegate the subdomain.
- **Day 1:** repo skeleton, pre-commit, `00-foundation`, GitHub OIDC; Go services + Dockerfiles; local test in kind.
- **Day 2:** `10-network`, `20-cluster` (EKS + Karpenter + Pod Identity + ArgoCD bootstrap). First `up`/`down` cycle.
- **Day 3:** GitOps platform apps (LBC, ExternalDNS, ESO, Kyverno); `30-data`; app deployed end-to-end over HTTPS.
- **Day 4:** CI workflows (app-ci, tf-plan with Infracost, platform-up/down).
- **Day 5:** observability, dashboards, SLO alerts; Argo Rollouts + AnalysisTemplate.
- **Day 6:** docs: architecture diagram, ADRs, runbooks, cost.md, README.
- **Day 7:** full dry run of the demo script from `platform-up` to `platform-down`; record a backup video.
- **Later (roadmap):** cosign + SBOM with Kyverno verifyImages, WAF, GuardDuty/CloudTrail, GitHub SSO for Argo CD/Grafana, a prod env.

## Cost estimate (ephemeral window)
EKS $0.10/h + 2× t4g.medium ≈ $0.07/h + NAT ≈ $0.05/h + ALB ≈ $0.03/h + RDS ≈ $0.02/h + Spot nodes, IPv4, and misc ≈ $0.03/h
→ **≈ $0.30/h ≈ $7/day**. Persistent layer: under $2/month (Route53 zone, KMS, Secrets). A 3-day demo window costs about $25 of credits.

## Risks and mitigations
- **Destroy leaves orphaned ALBs, ENIs, or Karpenter nodes, and the VPC delete fails.** `platform-down` first deletes the Argo apps and ingresses, waits for the LBC cleanup, deletes the Karpenter NodePools, and only then runs `terraform destroy` in reverse layer order.
- **Free Plan restrictions:** verify on Day 0.
- **The demo breaks live:** a pre-recorded backup video, plus bringing the env up 24h early and running a smoke test.

## Prerequisites to install (CachyOS/Arch; `paru` pulls from repos or the AUR)
```
paru -S terraform kubectl helm go kind k9s tflint terraform-docs trivy pre-commit github-cli \
        argocd kubectl-argo-rollouts k6 infracost checkov
```
Already installed: `aws`, `docker`. Also needed: a GitHub account/repo and a domain with registrar access for the NS delegation.

## Verification
- Locally: `pre-commit run -a` (fmt, tflint, checkov, terraform-docs); `go test ./...`; images build and run in kind.
- CI: a PR shows the plan and Infracost comment; merging to main produces a signed-off image in ECR and a tag bump in `gitops/`.
- `platform-up`: all Argo apps Healthy/Synced; `curl https://api.<domain>/healthz` returns 200; a message posted to the API lands in RDS through SQS and the worker.
- Each demo scenario runs twice in a row successfully.
- `platform-down`: no leftover billable resources (check with `aws resourcegroupstaggingapi get-resources` plus Cost Explorer the next day).
