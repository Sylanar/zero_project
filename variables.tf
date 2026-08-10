variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "aws_profile" {
  description = "AWS profile credentials"
  type        = string
}

variable "cluster_name" {
  description = "Name prefix for cluster resources (VPC, subnets, etc.)."
  type        = string
}

variable "vpc_cidr_block" {
  description = "IPv4 CIDR block for the cluster VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones that each receive one private subnet and one ASG-of-1 node."
  type        = list(string)
}

variable "default_tags" {
  description = "Tags applied to every taggable resource via the provider default_tags block."
  type        = map(string)
  default = {
    Project = "Spot-Stateful-Cluster"
  }
}

variable "nodes_total" {
  description = "Total number of stateful nodes (one ASG-of-1 each), spread round-robin across availability_zones."
  type        = number

  validation {
    condition     = var.nodes_total >= 1 && floor(var.nodes_total) == var.nodes_total
    error_message = "nodes_total must be a positive integer."
  }
}

variable "instance_type" {
  description = "EC2 instance type for every stateful node."
  type        = string
}

variable "data_volume_size_gb" {
  description = "Size in GiB of the durable data EBS volume paired to each ASG-of-1."
  type        = number
  default     = 100

  validation {
    condition     = var.data_volume_size_gb >= 1 && floor(var.data_volume_size_gb) == var.data_volume_size_gb
    error_message = "data_volume_size_gb must be a positive integer."
  }
}

variable "data_volume_type" {
  description = "EBS volume type for each node's durable data volume."
  type        = string
  default     = "gp3"
}

variable "elasticsearch_version" {
  description = "Elasticsearch version to cache in the S3 artifact bucket."
  type        = string
  default     = "9.4.4"
}

variable "elasticsearch_arch" {
  description = "Elasticsearch Linux architecture suffix (e.g. linux-aarch64, linux-x86_64)."
  type        = string
  default     = "linux-aarch64"
}