# ADR-0009: In-cluster Prometheus/Grafana/Loki

**Status:** Accepted

## Context
Canary analysis, SLO alerting and the demo need metrics, logs and dashboards. The environment lives for hours at a time.

## Decision
- **kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter), with 24h retention and no persistent volumes.
- **Loki** (single binary, filesystem on emptyDir) with **Alloy** tailing pod logs through the Kubernetes API.
- Grafana's CloudWatch data source (Pod Identity, read-only) for SQS/RDS metrics.
- Dashboards and PrometheusRules are code in `gitops/platform/config`.

## Consequences
- Zero extra AWS cost, and the stack starts in minutes with the environment.
- Data is lost when a pod restarts or the environment goes down. That is acceptable for ephemeral demos, but not for production.
- Prometheus is a single replica. Production would use HA pairs plus remote-write to durable storage.

## Alternatives considered
- **Amazon Managed Prometheus + Managed Grafana**: durable and scalable, but priced per sample and per user (Grafana workspace). A better fit for real teams, and the migration path is remote-write from the same Prometheus.
- **CloudWatch Container Insights**: native, but charged per metric/log volume, and weaker for PromQL-based canary analysis.
- **Grafana Cloud free tier**: lighter in-cluster footprint, but an external dependency and sign-up for a demo.
