variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "project" {
  type    = string
  default = "egp"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "app_namespace" {
  type    = string
  default = "orders"
}

variable "postgres_major_version" {
  type    = string
  default = "17"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "multi_az" {
  description = "Standby in a second AZ. Off in the demo to halve the cost (ADR-0011)."
  type        = bool
  default     = false
}
