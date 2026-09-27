# Inputs: the settings a caller can change without touching the module code

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. \"three-tier\" gives \"three-tier-vpc\"."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the whole VPC, e.g. \"10.0.0.0/16\"."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, like 10.0.0.0/16."
  }
}

variable "availability_zones" {
  description = "AZs to spread the subnets across. Subnet lists below need one CIDR per AZ, in the same order."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Use at least 2 availability zones. RDS Multi-AZ and the ALB both need two."
  }
}

variable "public_subnet_cidrs" {
  description = "One CIDR per AZ for the public subnets (ALB, NAT gateway)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones) && alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "public_subnet_cidrs needs one valid CIDR per availability zone."
  }
}

variable "private_app_subnet_cidrs" {
  description = "One CIDR per AZ for the private app subnets (EC2)."
  type        = list(string)

  validation {
    condition     = length(var.private_app_subnet_cidrs) == length(var.availability_zones) && alltrue([for c in var.private_app_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_app_subnet_cidrs needs one valid CIDR per availability zone."
  }
}

variable "private_db_subnet_cidrs" {
  description = "One CIDR per AZ for the private DB subnets (RDS)."
  type        = list(string)

  validation {
    condition     = length(var.private_db_subnet_cidrs) == length(var.availability_zones) && alltrue([for c in var.private_db_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_db_subnet_cidrs needs one valid CIDR per availability zone."
  }
}
