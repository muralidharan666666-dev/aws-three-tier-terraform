# ---------------------------------------------------------------------------
# VPC module: a VPC across N availability zones with three subnet tiers
# (public, private app, private DB), one internet gateway, one NAT gateway,
# public/private route tables, and a locked-down default security group.
#
# One NAT gateway on purpose (cost). If its AZ goes down, private subnets in
# the other AZs lose outbound internet. See Known gaps in the root README.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# ---------------------------------------------------------------------------
# Internet Gateway — gives public subnets two-way internet access
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ---------------------------------------------------------------------------
# Public subnets — ALB and NAT Gateway live here
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # ALB and NAT get their own IPs, nothing else here needs one

  tags = {
    Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

# ---------------------------------------------------------------------------
# Private app subnets — EC2 instances live here
# ---------------------------------------------------------------------------
resource "aws_subnet" "private_app" {
  count             = length(var.private_app_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.name_prefix}-private-app-${var.availability_zones[count.index]}"
    Tier = "app"
  }
}

# ---------------------------------------------------------------------------
# Private DB subnets — RDS lives here
# ---------------------------------------------------------------------------
resource "aws_subnet" "private_db" {
  count             = length(var.private_db_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.name_prefix}-private-db-${var.availability_zones[count.index]}"
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
    Name = "${var.name_prefix}-nat-eip"
  }
}

# ---------------------------------------------------------------------------
# NAT Gateway — outbound-only internet for private subnets
# Lives in a PUBLIC subnet because it must reach the IGW itself
# ---------------------------------------------------------------------------
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# PUBLIC route table
# 0.0.0.0/0 -> IGW is the ONLY thing that makes a subnet "public"
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
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
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-private-rt"
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
# Lock down the VPC's default security group. Nothing in this stack uses it,
# so it should allow nothing. No rules here = Terraform strips all its rules.
# ---------------------------------------------------------------------------
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-sg-locked"
  }
}
