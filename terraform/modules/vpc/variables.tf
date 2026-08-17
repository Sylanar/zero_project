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

variable "interface_endpoint_services" {
  description = "Interface VPC endpoint service short names (e.g. ec2, ssm). Empty = none."
  type        = set(string)
  default     = []
}

variable "interface_endpoint_subnet_azs" {
  description = "AZs that receive interface endpoint ENIs. Empty = every private subnet AZ."
  type        = list(string)
  default     = []
}

variable "enable_public_subnet" {
  description = "If true, create an IGW and one public subnet for the ingest gateway."
  type        = bool
  default     = false
}

variable "public_subnet_az" {
  description = "AZ for the public subnet when enable_public_subnet is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_public_subnet || contains(var.availability_zones, var.public_subnet_az)
    error_message = "public_subnet_az must be one of availability_zones when enable_public_subnet is true."
  }
}
