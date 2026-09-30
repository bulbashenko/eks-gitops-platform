# Runbooks

Short, symptom-first procedures. Every command assumes:

```bash
export AWS_REGION=eu-north-1
aws eks update-kubeconfig --region "$AWS_REGION" --name egp-demo
```

## Canary aborted (`api` Rollout Degraded)

**Meaning:** the AnalysisRun saw the canary's 5xx ratio above 5%. Users are already back on the stable version.

1. `kubectl argo rollouts get rollout api -n orders`: confirm it is aborted and weight is 0.
2. `kubectl -n orders get analysisrun --sort-by=.metadata.creationTimestamp | tail -1`, then `kubectl describe` it to see the measured values.
3. Grafana → Logs panel, or `{namespace="orders", app="api"} | json | level="ERROR"`.
4. Fix forward with a new commit, or revert the release commit. Either creates a new revision and a new canary.
5. Retry the same revision (only if the failure was environmental): `kubectl argo rollouts retry rollout api -n orders`.

## Messages in the DLQ

**Meaning:** the worker failed a message 5 times (the `OrdersWorkerFailing` alert fires first).

1. Check depth in the Grafana "SQS queue depth" panel, or run:
   `aws sqs get-queue-attributes --queue-url "$(terraform -chdir=infra/live/30-data output -raw orders_dlq_url)" --attribute-names ApproximateNumberOfMessages`
2. Read the worker errors: `kubectl -n orders logs deploy/worker | grep -i error | tail`
3. After fixing the cause, redrive the messages to the main queue:
   `aws sqs start-message-move-task --source-arn <dlq-arn>` (the destination defaults to the original queue).

## An Argo CD app stuck OutOfSync / Degraded after `make up`

The first sync takes about 10 minutes, and CRD-dependent apps retry until the CRDs exist.

1. `kubectl get applications -n argocd`
2. `kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}'` and `.status.operationState.message`
3. Common causes:
   - **`apps` missing**: 30-data has not been applied, so the `egp.io/data-layer=ready` label is absent.
   - **`image.tag is required`**: CI has not pushed images yet. Run `app-ci` on main.
   - **ExternalSecret not ready**: ESO or the Pod Identity association is still coming up. It retries on its own.
4. Force a refresh: `kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite`

## Pods Pending, no new nodes

1. `kubectl get nodeclaims` and `kubectl -n kube-system logs deploy/karpenter | tail -50`
2. Common causes:
   - the NodePool CPU limit (16) was reached (`kubectl get nodepool default -o yaml` shows `status.resources`);
   - no Spot or On-Demand capacity for the allowed arm64 types in these AZs (widen `instance-category` / sizes);
   - the pod requests more than an xlarge offers.

## Database credentials rotated, pods fail to connect

RDS rotates the managed master secret. ESO refreshes the Kubernetes Secret within 15 minutes, but running pods keep the old environment.

```bash
kubectl -n orders annotate externalsecret api-db worker-db force-sync=$(date +%s) --overwrite
kubectl argo rollouts restart api -n orders
kubectl -n orders rollout restart deploy/worker
```

## `make down` fails

- **VPC deletion blocked (DependencyViolation)**: controller-created resources are still there. List them with
  `aws resourcegroupstaggingapi get-resources --tag-filters Key=elbv2.k8s.aws/cluster,Values=egp-demo`
  and check `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`. Delete the leftovers, then run `make destroy-10-network`.
- **30-data destroy fails because the cluster is gone**: the Kubernetes provider cannot reach the API. Remove the in-cluster bits from state, then destroy:
  `terraform -chdir=infra/live/30-data state rm kubernetes_annotations.bridge kubernetes_labels.data_layer_ready`
- **Secrets Manager "scheduled for deletion" on the next up**: the Grafana secret uses `recovery_window_in_days = 0`. If a name is still reserved, restore and delete it:
  `aws secretsmanager restore-secret --secret-id egp/demo/grafana-admin`, then `aws secretsmanager delete-secret --secret-id egp/demo/grafana-admin --force-delete-without-recovery`

## Budget alert received

1. Cost Explorer → group by service, last 7 days.
2. Is the environment up when it should not be? Run `aws eks list-clusters`, and `make down` if so.
3. Check for orphans: `aws ec2 describe-instances --filters Name=tag-key,Values=karpenter.sh/nodepool`, load balancers, NAT gateways, and unattached EIPs.
