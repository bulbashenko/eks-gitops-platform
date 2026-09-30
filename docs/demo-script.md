# Live demo script (10–15 minutes)

## The day before

1. Run the **platform** workflow → `up`, with your current public IP (`curl -s ifconfig.me`) followed by `/32`.
   Or run it locally: `TF_VAR_ui_allowed_cidrs='["<ip>/32"]' make up`.
2. Wait about 10 minutes after the job finishes, then check:
   ```bash
   aws eks update-kubeconfig --region eu-north-1 --name egp-demo
   kubectl get applications -n argocd          # all Synced / Healthy
   curl -s https://api.demo.bulbashenko.com/version
   ```
3. Grafana password: `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d`.
   Argo CD password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
4. Run each scenario once, then reset (`FAULT_RATE: "0"`, merged and synced).
5. Open these tabs: the Argo CD app `api`, Rollouts dashboard (namespace `orders`), the Grafana "Orders — service overview" dashboard, and the GitHub repo.
6. Record a backup video of the whole script.

## On the day, at their office (5 minutes before you start)

```bash
# 1. Connect the laptop to their Wi-Fi, then:
export AWS_PROFILE=egp-admin
aws sso login --profile egp-admin     # browser login + MFA
make allow-ip                         # detects the new public IP, updates the ALB allowlist (~2-3 min)
```

It prints the three UI URLs with their HTTP status: `200`/`302` means reachable. If their network egresses from several
IPs (large corporate NAT pools), add them explicitly: `EXTRA=203.0.113.0/24 make allow-ip`. `KEEP=1` adds to the
list instead of replacing it. The script refuses to apply if the plan would touch anything besides the allowlist.

Fallback if their Wi-Fi blocks something: phone hotspot, then `make allow-ip` again.

## 0. Architecture (2 min)

Open [architecture.md](architecture.md) (the diagrams render on GitHub) and cover:
- the layers and why they are split (persistent vs ephemeral);
- how Terraform hands over to Argo CD (GitOps Bridge);
- that CI has no cluster credentials: it commits a tag.

## 1. Canary with automatic rollback (5 min)

**Story:** "Someone ships a release that fails 30% of requests. Watch the platform catch it."

```bash
git switch -c demo/bad-release
sed -i 's/FAULT_RATE: "0"/FAULT_RATE: "0.3"/' gitops/apps/api/values.yaml
git commit -am "api: new release" && git push -u origin demo/bad-release
gh pr create --fill && gh pr merge --squash --admin
```

Point out as it happens:
1. Argo CD syncs the `api` app, and the Rollout creates a canary ReplicaSet.
2. Rollouts dashboard: weight **20%**. The ALB is sending real traffic from `loadgen` to the canary.
3. Grafana "Error ratio by version": the canary hash jumps to ~30%, while stable stays at 0.
4. The AnalysisRun fails within ~1 minute and the Rollout goes **Degraded / aborted**. Weight returns to 0 and users see stable only.
5. SLO panel: the error budget took a small, bounded hit.

Reset: revert the PR (`FAULT_RATE: "0"`), then run `kubectl argo rollouts retry rollout api -n orders`, or let the revert create a new revision.

**Talking points:** exact traffic percentages come from ALB weighted target groups; the analysis compares only the canary pods (`rollout_hash` label); alternatives are Flagger or a mesh ([ADR-0008](adr/0008-progressive-delivery.md)).

## 2. Scale-out: HPA → Karpenter (4 min)

```bash
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type -w   # terminal 1
# terminal 2: ~150 rps of CPU-heavy requests for 3 minutes
docker run --rm -i grafana/k6 run - <<'EOF'
import http from 'k6/http';
export const options = { scenarios: { burn: { executor: 'constant-arrival-rate', rate: 150, timeUnit: '1s', duration: '3m', preAllocatedVUs: 200 } } };
export default function () { http.get('https://api.demo.bulbashenko.com/burn?ms=40'); }
EOF
```

Point out:
1. HPA desired replicas climb (CPU > 60%).
2. New pods go **Pending**: no room on the current nodes.
3. Karpenter launches a **Graviton Spot** node within about a minute ("Nodes by capacity type" panel), and the pods start.
4. After the test, consolidation removes the extra node within a few minutes.

**Talking points:** why controllers run on a fixed node group; how Spot interruptions are handled (interruption queue + PDBs); the NodePool CPU limit as a cost ceiling ([ADR-0002](adr/0002-karpenter.md)).

## 3. Policy enforcement (1 min)

Two admission layers, shown one at a time:

```bash
# Layer 1, Pod Security Admission (built in, "restricted" on orders):
kubectl -n orders run evil --image=nginx:latest --privileged
# → forbidden: violates PodSecurity "restricted:latest": privileged, allowPrivilegeEscalation, ...

# Layer 2, Kyverno. This pod satisfies PSA, but its image is not from our ECR:
kubectl apply -f docs/demo/untrusted-image.yaml
# → denied: Policy restrict-app-images-to-ecr failed: Images in 'orders' must come from this account's ECR

# Cluster-wide rule outside orders:
kubectl -n default run lazy --image=nginx
# → denied: Policy disallow-latest-tag failed: Images must use an explicit, immutable tag
```

**Talking points:** PSA covers the pod-security baseline for free. Kyverno adds organisation rules (trusted registry, tags, limits) as CEL `ValidatingPolicy`, synced by Argo CD. The next step is cosign `verifyImages` ([ADR-0010](adr/0010-kyverno.md)).

## 4. Wrap-up (2 min)

- Cost: about $0.30/h while up, under $2/month when down ([ADR-0011](adr/0011-ephemeral-environments.md)).
- What changes for production: see the end of [architecture.md](architecture.md).
- Then tear it down: **platform** workflow → `down`.

## Likely questions

| Question | Short answer |
|---|---|
| Why not ECS? | Ecosystem for GitOps/policy/canaries; ECS or EKS Auto Mode is fine for a small team ([ADR-0001](adr/0001-eks.md)) |
| What if Argo CD is down? | Workloads keep running; only reconciliation pauses. Git still records intent |
| How do you roll back? | `git revert` (desired state), or `kubectl argo rollouts undo` in an emergency; Argo CD then shows the drift |
| How are secrets handled? | RDS-generated → Secrets Manager → ESO. Apps have no secret-read permission ([ADR-0007](adr/0007-secrets.md)) |
| Terraform state safety? | S3 + KMS + versioning + native locking; per-layer state; read-only plan role on PRs |
| Multi-account? | One account per env under Organizations; the foundation layer becomes per-account; GitOps Bridge already supports multiple clusters |
| What would you monitor first in prod? | SLO burn-rate alerts, DLQ depth, Karpenter pending pods, node NotReady, RDS storage/connections |
