# Networking: the VPC comes from modules/vpc, the security groups stay here
# because they're specific to this app's three tiers.

module "vpc" {
  source = "./modules/vpc"

  name_prefix              = var.project_name
  vpc_cidr                 = var.vpc_cidr
  availability_zones       = var.availability_zones
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
}

# ---------------------------------------------------------------------------
# SG-ALB — the only security group exposed to the internet
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  #checkov:skip=CKV_AWS_260:Public ALB has to accept port 80 from the internet. No domain name so no ACM certificate yet. HTTPS is the first item in Known gaps
  #checkov:skip=CKV_AWS_382:ALB needs outbound to reach the targets and health checks. Could be narrowed to SG-App later
  name        = "${var.project_name}-sg-alb"
  description = "ALB: accepts HTTP from the internet"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-alb"
    Tier = "alb"
  }
}

# ---------------------------------------------------------------------------
# SG-App — EC2 instances. Accepts traffic ONLY from SG-ALB.
# Note: security_groups, not cidr_blocks. Identity, not IP address.
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  #checkov:skip=CKV_AWS_382:App tier needs outbound through NAT for dnf, SSM, CloudWatch and Secrets Manager. VPC endpoints would remove this but cost more than NAT
  name        = "${var.project_name}-sg-app"
  description = "App tier: accepts HTTP only from the ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (package installs via NAT, SSM, RDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-app"
    Tier = "app"
  }
}

# ---------------------------------------------------------------------------
# SG-DB — RDS. Accepts MySQL ONLY from SG-App.
# No path from the internet exists. Not by firewall rule — by topology.
# ---------------------------------------------------------------------------
resource "aws_security_group" "db" {
  name        = "${var.project_name}-sg-db"
  description = "DB tier: accepts MySQL only from the app tier"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from app tier only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # No outbound rules. The database never starts a connection, it only
  # answers the app tier, and SGs are stateful so the replies still go out.
  egress = []

  tags = {
    Name = "${var.project_name}-sg-db"
    Tier = "db"
  }
}
