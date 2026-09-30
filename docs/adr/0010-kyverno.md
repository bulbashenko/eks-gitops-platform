# ADR-0010: Kyverno for admission policy

**Status:** Accepted

## Context
Guardrails (no privileged pods, no `:latest`, only trusted images, resource limits) should be enforced at admission, not only in code review.

## Decision
Use **Kyverno** `ValidatingPolicy` resources (CEL, `policies.kyverno.io/v1`; the older `ClusterPolicy` is deprecated as of Kyverno 1.19) in `gitops/platform/kyverno-policies`:
- cluster-wide (excluding `kube-system`): no privileged containers, no `:latest` or untagged images;
- namespace `orders`: images only from our ECR (`*.dkr.ecr.*.amazonaws.com/egp/*`), plus non-root, read-only root filesystem, no privilege escalation, and CPU/memory requests with a memory limit.

Pod Security Admission `restricted` is also enforced on `orders` as a built-in second layer.

## Consequences
- Policies are YAML, reviewable by any Kubernetes engineer, and synced by Argo CD like everything else.
- The admission webhook is a dependency for pod creation. It runs with 1 replica in the demo; production runs 3 with PDBs.
- Platform namespaces are exempt from the strictest rules because some add-ons need host access. Those exemptions are explicit and listed in the policies.

## Alternatives considered
- **OPA Gatekeeper**: very flexible (Rego), but harder to read and write for app teams.
- **ValidatingAdmissionPolicy (CEL, built into Kubernetes)**: no extra component. Good for simple rules, but it lacks mutation, generation and image-verification features that are on the roadmap (cosign `verifyImages`).
