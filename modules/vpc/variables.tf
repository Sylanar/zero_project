variable "name" {
  description = "Name prefix applied to VPC and subnet Name tags."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones that each receive exactly one private subnet."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) > 0
    error_message = "At least one availability zone is required."
  }
}

variable "private_subnet_newbits" {
  description = "Additional bits used with cidrsubnet() to size each private subnet from the VPC CIDR."
  type        = number
  default     = 8
}

variable "tags" {
  description = "Additional tags merged onto every taggable resource."
  type        = map(string)
  default = {
    Project = "Spot-Stateful-Cluster"
  }
}
