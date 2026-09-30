output "db_endpoint" {
  value = module.db.db_instance_address
}

output "db_master_secret_arn" {
  value = module.db.db_instance_master_user_secret_arn
}

output "orders_queue_url" {
  value = module.orders_queue.queue_url
}

output "orders_dlq_url" {
  value = module.orders_queue.dead_letter_queue_url
}

output "receipts_bucket" {
  value = module.receipts.s3_bucket_id
}
