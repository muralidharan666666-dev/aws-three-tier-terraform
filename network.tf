# Networking: VPC, subnets, gateways, route tables and security groups

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ---------------------------------------------------------------------------
# Internet Gateway — gives public subnets two-way internet access
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ---------------------------------------------------------------------------
# Public subnets — ALB and NAT Gateway live here
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # ALB and NAT get their own IPs, nothing else here needs one

  tags = {
    Name = "${var.project_name}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

# ---------------------------------------------------------------------------
# Private app subnets — EC2 instances live here
# ---------------------------------------------------------------------------
resource "aws_subnet" "private_app" {
  count             = length(var.private_app_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-private-app-${var.availability_zones[count.index]}"
    Tier = "app"
  }
}

# ---------------------------------------------------------------------------
# Private DB subnets — RDS lives here
# ---------------------------------------------------------------------------
resource "aws_subnet" "private_db" {
  count             = length(var.private_db_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project_name}-private-db-${var.availability_zones[count.index]}"
    Tier = "db"
  }
}

# ---------------------------------------------------------------------------
# Elastic IP for the NAT Gateway
# NAT needs a stable public IP it owns to translate outbound traffic
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

# ---------------------------------------------------------------------------
# NAT Gateway — outbound-only internet for private subnets
# Lives in a PUBLIC subnet because it must reach the IGW itself
# ---------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# PUBLIC route table
# 0.0.0.0/0 -> IGW is the ONLY thing that makes a subnet "public"
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# PRIVATE route table
# 0.0.0.0/0 -> NAT = outbound only. Shared by app and DB subnets.
# ---------------------------------------------------------------------------
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private_app" {
  count          = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# SG-ALB — the only security group exposed to the internet
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  #checkov:skip=CKV_AWS_260:Public ALB has to accept port 80 from the internet. No domain name so no ACM certificate yet. HTTPS is the first item in Known gaps
  #checkov:skip=CKV_AWS_382:ALB needs outbound to reach the targets and health checks. Could be narrowed to SG-App later
  name        = "${var.project_name}-sg-alb"
  description = "ALB: accepts HTTP from the internet"
  vpc_id      = aws_vpc.main.id

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
  vpc_id      = aws_vpc.main.id

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
  vpc_id      = aws_vpc.main.id

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

# ---------------------------------------------------------------------------
# Lock down the VPC's default security group. Nothing in this stack uses it,
# so it should allow nothing. No rules here = Terraform strips all its rules.
# ---------------------------------------------------------------------------
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-default-sg-locked"
  }
}
