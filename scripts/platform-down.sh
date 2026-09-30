#!/usr/bin/env bash
# Destroys the ephemeral environment without orphaning AWS resources that controllers
# created outside Terraform (ALBs and target groups from the LB controller, EC2 instances
# from Karpenter). Those would otherwise block the VPC deletion and keep costing money.
set -euo pipefail

PROJECT=${PROJECT:-egp}
ENVIRONMENT=${ENVIRONMENT:-demo}
REGION=${REGION:-${AWS_REGION:-eu-central-1}}
CLUSTER="${PROJECT}-${ENVIRONMENT}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TIMEOUT=${TIMEOUT:-900}

log() { printf '\n==> %s\n' "$*"; }

wait_for() { # description, command printing a count; waits until it prints 0
  local what=$1; shift
  local deadline=$((SECONDS + TIMEOUT)) n
  while :; do
    n=$("$@" 2>/dev/null || echo 0)
    [ "$n" -eq 0 ] && { echo "    $what: done"; return 0; }
    [ "$SECONDS" -ge "$deadline" ] && { echo "    $what: still $n after ${TIMEOUT}s, continuing"; return 0; }
    echo "    $what: $n remaining"
    sleep 15
  done
}

alb_count() {
  aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER}" \
    --query 'length(ResourceTagMappingList)' --output text
}

karpenter_instance_count() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag-key,Values=karpenter.sh/nodepool" "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER}" \
              "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query 'length(Reservations[].Instances[])' --output text
}

if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  KUBECONFIG=$(mktemp)
  export KUBECONFIG
  trap 'rm -f "$KUBECONFIG"' EXIT
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

  log "1/4 Pausing Argo CD so it does not recreate what we delete"
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 || true
  kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=0 || true

  log "2/4 Deleting Ingresses and LoadBalancer Services (the LB controller removes the ALB)"
  kubectl delete ingress --all --all-namespaces --wait=false || true
  kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
    while read -r ns name; do kubectl -n "$ns" delete svc "$name" --wait=false; done

  log "3/4 Deleting Karpenter NodePools (Karpenter drains and terminates its nodes)"
  kubectl delete nodepools.karpenter.sh --all --wait=false || true

  wait_for "load balancers" alb_count
  wait_for "Karpenter instances" karpenter_instance_count
else
  log "Cluster ${CLUSTER} not found; skipping in-cluster cleanup"
fi

log "4/4 terraform destroy (data -> cluster -> network)"
for layer in 30-data 20-cluster 10-network; do
  make -C "$ROOT" "destroy-${layer}" AUTO_APPROVE=1
done

log "Done. Persistent layer (00-foundation) is untouched."
