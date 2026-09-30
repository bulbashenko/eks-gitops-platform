# Platform credentials are generated here and stored in Secrets Manager; External Secrets
# syncs them into the cluster. Nothing sensitive is committed or passed through Helm values.

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  # checkov:skip=CKV_AWS_149: AWS-managed key is sufficient for an ephemeral demo credential
  # checkov:skip=CKV2_AWS_57: regenerated on every environment build, which outpaces rotation
  name        = "${var.project}/${var.environment}/grafana-admin"
  description = "Grafana admin credentials"
  # Ephemeral environment: delete immediately so the next `make up` can reuse the name.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.grafana_admin.result
  })
}

# Grafana reads RDS and SQS metrics from CloudWatch.
module "grafana_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name = "${local.name}-grafana"
  additional_policy_arns = {
    CloudWatchReadOnlyAccess = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "monitoring"
      service_account = "kube-prometheus-stack-grafana"
    }
  }
}
