output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "intra_subnet_ids" {
  value = module.vpc.intra_subnets
}

output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}
