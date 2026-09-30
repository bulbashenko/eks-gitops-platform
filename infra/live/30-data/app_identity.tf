# Least-privilege Pod Identity per service: the api can only send, the worker can only
# consume and write receipts. Neither can read the database secret; External Secrets does that.

module "api_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                 = "${local.name}-api"
  attach_custom_policy = true
  policy_statements = [{
    sid       = "SendOrders"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [module.orders_queue.queue_arn]
  }]

  associations = {
    this = {
      cluster_name    = local.cluster.cluster_name
      namespace       = var.app_namespace
      service_account = "api"
    }
  }
}

module "worker_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                 = "${local.name}-worker"
  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "ConsumeOrders"
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
      resources = [module.orders_queue.queue_arn]
    },
    {
      sid       = "WriteReceipts"
      actions   = ["s3:PutObject"]
      resources = ["${module.receipts.s3_bucket_arn}/receipts/*"]
    },
  ]

  associations = {
    this = {
      cluster_name    = local.cluster.cluster_name
      namespace       = var.app_namespace
      service_account = "worker"
    }
  }
}

# Publish data-layer facts to Argo CD (GitOps Bridge).
# Every server-side-apply resource needs its OWN field manager: an apply declares the complete
# set of fields that manager owns, so two resources sharing a manager delete each other's fields.
resource "kubernetes_annotations" "bridge" {
  api_version   = "v1"
  kind          = "Secret"
  field_manager = "terraform-30-data-bridge"
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
  }
  annotations = {
    orders_queue_url     = module.orders_queue.queue_url
    orders_dlq_name      = module.orders_queue.dead_letter_queue_name
    receipts_bucket      = module.receipts.s3_bucket_id
    db_host              = module.db.db_instance_address
    db_port              = tostring(module.db.db_instance_port)
    db_name              = module.db.db_instance_name
    db_master_secret_arn = module.db.db_instance_master_user_secret_arn
  }
}

# Gate for the apps ApplicationSet: services are generated only once this label exists.
resource "kubernetes_labels" "data_layer_ready" {
  api_version   = "v1"
  kind          = "Secret"
  field_manager = "terraform-30-data"
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
  }
  labels = {
    "egp.io/data-layer" = "ready"
  }

  depends_on = [kubernetes_annotations.bridge, module.api_pod_identity, module.worker_pod_identity]
}
