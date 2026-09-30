# Argo CD bootstrap + "GitOps Bridge" (ADR-0005).
# Terraform knows AWS facts (queue names, role names, endpoints) that the Helm values in Git need.
# Instead of templating them into Git, they are published as annotations on Argo CD's
# in-cluster Secret. ApplicationSets read them via the cluster generator.

locals {
  ui_source_ip_condition = jsonencode([{
    field          = "source-ip"
    sourceIpConfig = { values = var.ui_allowed_cidrs }
  }])

  # Shared ALB settings; every Ingress joins the same IngressGroup, so there is one ALB.
  alb_annotations = {
    "alb.ingress.kubernetes.io/group.name"      = local.name
    "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    "alb.ingress.kubernetes.io/certificate-arn" = local.foundation.certificate_arn
  }

  bridge_annotations = {
    environment              = var.environment
    aws_region               = var.region
    aws_account_id           = local.account_id
    cluster_name             = module.eks.cluster_name
    cluster_endpoint         = module.eks.cluster_endpoint
    vpc_id                   = local.network.vpc_id
    vpc_cidr                 = local.network.vpc_cidr
    domain                   = local.foundation.domain
    acm_certificate_arn      = local.foundation.certificate_arn
    alb_group_name           = local.name
    ui_source_ip_condition   = local.ui_source_ip_condition
    karpenter_queue_name     = module.karpenter.queue_name
    karpenter_node_role_name = module.karpenter.node_iam_role_name
    gitops_repo_url          = var.gitops_repo_url
    gitops_revision          = var.gitops_revision
    grafana_admin_secret     = aws_secretsmanager_secret.grafana_admin.name
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.4"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    global = {
      domain       = "argocd.${local.foundation.domain}"
      nodeSelector = { "node-role.egp.io/system" = "true" }
    }
    configs = {
      # TLS terminates at the ALB.
      params = { "server.insecure" = true }
      cm = {
        "timeout.reconciliation" = "60s"
        # Argo Rollouts health checks are built in; Karpenter NodeClaims churn constantly.
        "resource.exclusions" = yamlencode([{
          apiGroups = ["karpenter.sh"]
          kinds     = ["NodeClaim"]
          clusters  = ["*"]
        }])
      }
    }
    dex           = { enabled = false }
    notifications = { enabled = false }
    server = {
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        annotations = merge(local.alb_annotations, {
          "alb.ingress.kubernetes.io/conditions.argocd-server" = local.ui_source_ip_condition
          "alb.ingress.kubernetes.io/healthcheck-path"         = "/healthz"
        })
      }
    }
  })]

  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "environment"                    = var.environment
    }
  }
  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }

  lifecycle {
    # Annotations and later labels are owned field-by-field by kubernetes_annotations /
    # kubernetes_labels (here and in 30-data); this resource only creates the Secret.
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_annotations" "bridge" {
  api_version   = "v1"
  kind          = "Secret"
  field_manager = "terraform-20-cluster"
  metadata {
    name      = kubernetes_secret_v1.in_cluster.metadata[0].name
    namespace = "argocd"
  }
  annotations = local.bridge_annotations
}

# The root "app of apps": everything else comes from gitops/bootstrap.
resource "helm_release" "root_app" {
  name       = "argocd-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.6"

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "gitops/bootstrap"
          directory      = { recurse = true }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [kubernetes_annotations.bridge]
}
