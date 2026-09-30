# ADR-0008: Canary releases with Argo Rollouts on the ALB

**Status:** Accepted

## Context
A rolling update sends 100% of traffic to a bad version within minutes. Detecting regressions should be automatic and based on real traffic.

## Decision
- The api runs as an **Argo Rollout** with a canary strategy: 20% → pause 2m → 50% → pause 2m → 100%.
- Traffic is split at the **ALB with weighted target groups** (Rollouts writes the forward action on the Ingress), so the percentages are exact and independent of replica counts.
- A **background AnalysisRun** queries Prometheus every 30s for the canary ReplicaSet's 5xx ratio. PodMonitor relabeling adds `rollout_hash`, so stable traffic cannot dilute the signal. One failure (> 5%) aborts, and traffic returns to 100% stable.
- The `loadgen` deployment sends steady synthetic traffic through the public ALB, so every release is judged on data.

## Consequences
- A bad release reaches at most 20% of requests for about a minute before automatic rollback. This is the centrepiece of the demo (set `FAULT_RATE=0.3`).
- Every deploy takes about 5 minutes longer, a deliberate trade for safety.
- Argo CD must ignore the fields Rollouts mutates (Service selectors, the Ingress action annotation), which is configured in the apps ApplicationSet.
- Analysis on error rate only. Latency (p95) and business metrics are natural next steps.

## Alternatives considered
- **Flagger**: similar capability, but pairs more naturally with Flux and service meshes.
- **Service mesh (Istio/Linkerd) traffic splitting**: finer control (headers, mirroring) at significant operational cost. The ALB already exists.
- **Blue/green**: all-or-nothing switch with a doubled footprint, and no gradual exposure.
