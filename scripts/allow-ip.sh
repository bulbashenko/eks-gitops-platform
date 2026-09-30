#!/usr/bin/env bash
# Points the UI allowlist (Argo CD, Grafana, Argo Rollouts) at this machine's current public IP,
# e.g. after joining a new Wi-Fi network. The public api is not affected.
#
#   make allow-ip                              # replace the allowlist with this IP
#   KEEP=1 make allow-ip                       # add this IP to the existing allowlist
#   EXTRA=203.0.113.7/32,198.51.100.0/24 make allow-ip   # also allow other CIDRs
#
# Safety: it applies the 20-cluster layer, but only after checking that the plan touches
# nothing except the two resources that carry the allowlist.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT=${PROJECT:-egp}
ENVIRONMENT=${ENVIRONMENT:-demo}
REGION=${REGION:-${AWS_REGION:-eu-north-1}}
REPO=${REPO:-bulbashenko/eks-gitops-platform}
CLUSTER="${PROJECT}-${ENVIRONMENT}"
LAYER="$ROOT/infra/live/20-cluster"
ALLOWED_CHANGES='["helm_release.argocd","kubernetes_annotations.bridge"]'

die() { echo "error: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

aws sts get-caller-identity >/dev/null 2>&1 ||
  die "no valid AWS session. Run: aws sso login --profile ${AWS_PROFILE:-egp-admin}"
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 ||
  die "cluster $CLUSTER is not running (start it with: make up, or the platform workflow)"

KUBECONFIG=$(mktemp)
PLAN=$(mktemp)
export KUBECONFIG
trap 'rm -f "$KUBECONFIG" "$PLAN"' EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

# --- Build the new allowlist ------------------------------------------------------------
ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
[[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "could not determine public IPv4 (got '$ip')"
log "Public IP: $ip"

cidrs=("$ip/32")
if [ -n "${EXTRA:-}" ]; then
  IFS=',' read -ra extra <<<"$EXTRA"
  cidrs+=("${extra[@]}")
fi
if [ "${KEEP:-0}" = 1 ]; then
  mapfile -t current < <(kubectl -n argocd get secret in-cluster \
    -o jsonpath='{.metadata.annotations.ui_source_ip_condition}' | jq -r '.[0].sourceIpConfig.values[]')
  cidrs+=("${current[@]}")
fi
for c in "${cidrs[@]}"; do
  [[ $c =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "not an IPv4 CIDR: $c"
done
allow=$(printf '%s\n' "${cidrs[@]}" | jq -R . | jq -sc 'unique')
log "UI allowlist: $allow"

# --- Plan with the same inputs CI uses, then verify the blast radius ---------------------
admins=${TF_VAR_cluster_admin_arns:-$(gh variable get CLUSTER_ADMIN_ARNS -R "$REPO" 2>/dev/null || true)}
[ -n "$admins" ] || die "set TF_VAR_cluster_admin_arns or the CLUSTER_ADMIN_ARNS GitHub variable"
export TF_VAR_ui_allowed_cidrs="$allow" TF_VAR_cluster_admin_arns="$admins"

make -s -C "$ROOT" init-20-cluster >/dev/null
terraform -chdir="$LAYER" plan -input=false -lock-timeout=60s -out="$PLAN" >/dev/null

changes=$(terraform -chdir="$LAYER" show -json "$PLAN" |
  jq -c '[.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | .address]')
if [ "$changes" = "[]" ]; then
  log "Allowlist already up to date, nothing to do."
else
  unexpected=$(jq -nc --argjson c "$changes" --argjson ok "$ALLOWED_CHANGES" '$c - $ok')
  [ "$unexpected" = "[]" ] || die "plan would also change $unexpected. Refusing; run 'make plan-20-cluster' and investigate."
  log "Applying: $changes"
  terraform -chdir="$LAYER" apply -input=false -lock-timeout=60s "$PLAN" >/dev/null
fi

# Keep CI's read-only plans consistent with reality.
gh variable set UI_ALLOWED_CIDRS -R "$REPO" -b "$allow" >/dev/null 2>&1 ||
  echo "warning: could not update the UI_ALLOWED_CIDRS GitHub variable (gh not logged in?)" >&2

# --- Wait until every UI Ingress carries the new condition --------------------------------
log "Waiting for Argo CD to roll the new rule out to the ALB..."
for app in argo-rollouts kube-prometheus-stack; do
  kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
done
deadline=$((SECONDS + 300))
while :; do
  # Every UI condition must carry exactly the new list (checking only for this IP would pass
  # immediately when the IP was already allowed and only EXTRA/KEEP entries changed).
  pending=$(kubectl get ingress -A -o json | jq --argjson want "$allow" '
    [.items[] | .metadata.annotations // {} | to_entries[]
     | select(.key | startswith("alb.ingress.kubernetes.io/conditions."))
     | select((.value | fromjson | .[0].sourceIpConfig.values | unique) != $want)] | length')
  [ "$pending" -eq 0 ] && break
  [ "$SECONDS" -ge "$deadline" ] && die "some Ingresses still lack the new allowlist after 5 minutes; check the argo-rollouts and kube-prometheus-stack apps"
  sleep 10
done
sleep 20 # the ALB controller reconciles the listener rules right after the Ingress changes

domain=$(kubectl -n argocd get secret in-cluster -o jsonpath='{.metadata.annotations.domain}')
log "Done. From this network you can open:"
for h in argocd grafana rollouts; do
  printf '    https://%s.%s  (HTTP %s)\n' "$h" "$domain" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$h.$domain/")"
done
