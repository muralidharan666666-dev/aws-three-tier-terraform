# vpc module

A VPC spread across two or more availability zones, with three subnet tiers:

- **public**: the load balancer and the NAT gateway
- **private app**: the EC2 instances
- **private DB**: RDS

Also creates one internet gateway, one NAT gateway, a public and a private route table, and locks down the VPC's default security group so it allows nothing.

Security groups aren't in here. They depend on what's running in the VPC, so they stay with the app in the root.

## Usage

```hcl
module "vpc" {
  source = "./modules/vpc"

  name_prefix              = "three-tier"
  vpc_cidr                 = "10.0.0.0/16"
  availability_zones       = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs      = ["10.0.1.0/24", "10.0.2.0/24"]
  private_app_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
  private_db_subnet_cidrs  = ["10.0.21.0/24", "10.0.22.0/24"]
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `name_prefix` | `string` | Prefix for every resource name |
| `vpc_cidr` | `string` | CIDR block for the VPC. Must be a valid CIDR |
| `availability_zones` | `list(string)` | AZs to use. At least 2 |
| `public_subnet_cidrs` | `list(string)` | One CIDR per AZ |
| `private_app_subnet_cidrs` | `list(string)` | One CIDR per AZ |
| `private_db_subnet_cidrs` | `list(string)` | One CIDR per AZ |

## Outputs

| Name | Description |
|------|-------------|
| `vpc_id` | ID of the VPC |
| `vpc_cidr_block` | CIDR block of the VPC |
| `public_subnet_ids` | Public subnet IDs, one per AZ |
| `private_app_subnet_ids` | Private app subnet IDs, one per AZ |
| `private_db_subnet_ids` | Private DB subnet IDs, one per AZ |
| `nat_gateway_id` | ID of the NAT gateway |

## Notes

- Only one NAT gateway, to save money. If its AZ goes down, private subnets in the other AZs lose outbound internet.
- The inputs are checked before anything reaches AWS: a bad CIDR, fewer than 2 AZs, or a subnet list that doesn't match the number of AZs fails at `terraform plan` with a clear message.
