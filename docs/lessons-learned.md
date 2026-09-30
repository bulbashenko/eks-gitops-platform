# Lessons learned from the first deployment

Issues found while bringing the platform up in a fresh AWS account (eu-north-1, September 2026). They were invisible to static checks. Each entry gives the symptom, the root cause and the fix that is now in code.

## 1. GitHub OIDC: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

- **Symptom:** every CI job failed to assume its AWS role, even though the trust policy matched `repo:owner/repo:ref:refs/heads/main`.
- **Cause:** new repositories use GitHub's **immutable subject** format, `repo:<owner>@<owner_id>/<repo>@<repo_id>:…`, which can be checked with `gh api repos/<owner>/<repo>/actions/oidc/customization/sub`.
- **Fix:** the `github-oidc` module takes a `subject_prefix`, and the foundation pins it to the numeric IDs.
- **Why it matters:** the classic format is vulnerable to deleting and recreating a repository under the same name. Pinning the IDs closes that.

## 2. Terraform: `Invalid for_each argument` in our own module

- **Symptom:** the first foundation plan failed.
- **Cause:** the inline-policy resource filtered roles with `if v.inline_policy_json != null`. The JSON referenced ECR ARNs that did not exist yet, so even the *set of keys* was unknown at plan time.
- **Fix:** inline policies became a separate `map(string)` keyed by role name. The keys are static and only the values are unknown.

## 3. EKS access entries reject path-less Identity Center role ARNs

- **Symptom:** `CreateAccessEntry … InvalidParameterException: The specified principalArn is invalid`.
- **Cause:** IAM Identity Center roles live under `/aws-reserved/sso.amazonaws.com/<region>/`. The old `aws-auth` ConfigMap required the path to be stripped, but access entries need the **full ARN including the path**.
- **Fix:** documented in the README (`aws iam list-roles --path-prefix /aws-reserved/`). Root cannot be used at all, which is one more reason to use Identity Center.

## 4. Two Terraform resources sharing one server-side-apply field manager

- **Symptom:** the apps rendered with an empty queue URL, database host and so on. The GitOps Bridge annotations written by `30-data` had disappeared, but its label was present.
- **Cause:** `kubernetes_annotations` and `kubernetes_labels` both used `field_manager = "terraform-30-data"`. In server-side apply, each apply declares the **complete** set of fields a manager owns, so applying the label removed the annotations that the same manager had applied a moment earlier.
- **Fix:** one field manager per applied object (`terraform-30-data-bridge`).
- **Why it matters:** a subtle SSA rule that anyone sharing objects between tools (Terraform, Argo CD, controllers) eventually hits.

## 5. Permanent OutOfSync in Argo CD (PodMonitor, Rollout, Kyverno)

- **Symptom:** applications were healthy but never Synced, and the client-side diff showed nothing useful.
- **Cause:** CRD defaulting (`relabelings[].action: replace`) and mutating webhooks (Kyverno policy defaults) add fields after apply.
- **Fix:** `controller.diff.server.side: true`. Argo CD now diffs against a server-side dry-run apply, which includes defaults and webhook mutations.

## 6. Kyverno 1.19 deprecates `ClusterPolicy`

- **Symptom:** a deprecation warning on every policy read, plus drift.
- **Fix:** migrated to `ValidatingPolicy` (`policies.kyverno.io/v1`, CEL), the same language as Kubernetes' built-in ValidatingAdmissionPolicy.

## 7. Loki crash loop: `mkdir /var/loki: read-only file system`

- **Cause:** with persistence disabled, the chart mounts no volume at the data path, and the container's root filesystem is read-only.
- **Fix:** explicit `emptyDir` at `/var/loki` (the environment is ephemeral by design).

## 8. Karpenter never launched Spot

- **Symptom:** every node was On-Demand. The logs showed `AuthFailure.ServiceLinkedRoleCreationNotPermitted … UnfulfillableCapacity`, and Karpenter silently fell back.
- **Cause:** a new account has no `AWSServiceRoleForEC2Spot`. EC2 creates it on the first Spot request only if the caller may create service-linked roles, and Karpenter's role (correctly) may not.
- **Fix:** `aws_iam_service_linked_role "spot"` in the persistent foundation layer. The next scale-out launched `m8g.medium` Spot (Graviton4).

## 9. SLO recording rule returned nothing when there were no errors

- **Cause:** `sum(rate(...{code=~"5.."}))` is an **empty vector**, not 0, when no 5xx series exist, so the ratio was empty too.
- **Fix:** `(… or vector(0)) / …`.

## 10. Tooling

- CachyOS sets `MAKEFLAGS=-j$(nproc)` for package builds, which made `make up` run layers in parallel ("Unable to find remote state"). Fixed with `.NOTPARALLEL:` in the Makefile.
- EKS allows control-plane → node traffic only on specific ports, so `kubectl get --raw …/services/prometheus:9090/proxy` hangs. Use `kubectl port-forward` (via the kubelet) instead.

## Verified end to end

| Check | Result |
|---|---|
| `POST /orders` → SQS → worker → RDS + S3 receipt | processed in ~0.2 s |
| Bad release (`FAULT_RATE=0.3`) | canary at 20%, analysis measured 33% / 29% 5xx, **auto-aborted about 90 s after reaching 20%** |
| Good release (new image from CI) | 20% → 50% → 100% in 4.5 min, analysis Successful |
| k6, 150 rps CPU-heavy for 3 min | HPA 2 → 12 pods, Karpenter added nodes in ~30 s, **0 failed of 26,801 requests**, consolidation removed the nodes afterwards |
| Admission | PSA denies the privileged pod; Kyverno denies the non-ECR image and the untagged image |
