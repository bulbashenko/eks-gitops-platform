variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "project" {
  type    = string
  default = "egp"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cheap, but a single-AZ egress dependency). Set false for one per AZ. See ADR-0003."
  type        = bool
  default     = true
}

variable "azs" {
  description = "Pinned explicitly so the subnet layout never shifts when AWS adds a zone."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}
