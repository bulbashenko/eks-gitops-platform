# ADR-0002: Karpenter for workload capacity, a small node group for controllers

**Status:** Accepted

## Context
Workloads should scale quickly and cheaply. Cluster Autoscaler scales pre-defined node groups (one instance shape each). Controllers must keep running while capacity changes underneath them.

## Decision
- A **managed node group** (2 × t4g.medium, On-Demand, labelled `node-role.egp.io/system`) runs cluster controllers, including Karpenter itself.
- **Karpenter** provisions everything else from one NodePool: arm64 (Graviton), Spot preferred with On-Demand fallback, c/m/r/t families, consolidation after 1 minute, a 16 vCPU ceiling, weekly node expiry.
- Application pods require the `node-role.egp.io/workload` label, so they always run on Karpenter nodes.

## Consequences
- New capacity arrives in about a minute and is shaped to the pending pods. Spot + Graviton is roughly 60–70% cheaper than x86 On-Demand.
- Spot interruptions are handled: Karpenter watches the EventBridge → SQS interruption queue and drains nodes ahead of reclaim. PodDisruptionBudgets protect availability.
- All images must be multi-arch; CI builds amd64 + arm64.
- The NodePool limit is a hard cost ceiling, but a mis-sized workload can still hit it. Pending pods are on the dashboard.

## Alternatives considered
- **Cluster Autoscaler + multiple node groups**: slower, one shape per group, and poor bin-packing.
- **Fargate**: no DaemonSets, higher per-pod price, slower pod start.
- **Karpenter for everything**: a controller running on capacity it manages can evict itself.
