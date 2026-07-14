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
  map_public_ip_on_launch = true

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

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-db"
    Tier = "db"
  }
}
# ---------------------------------------------------------------------------
# Look up the latest Amazon Linux 2023 AMI
# `data` reads existing info — it creates nothing
# Not hardcoding the AMI ID: those go stale and differ per region
# ---------------------------------------------------------------------------
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Launch Template — the blueprint the ASG stamps instances from
# ---------------------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_ssm.name
  }


  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    dnf update -y

    # SSM Agent — pre-installed on standard AL2023, but NOT on the minimal
    # variant. Installing explicitly so secure access doesn't silently depend
    # on which AMI variant the data source returns.
    dnf install -y amazon-ssm-agent
    systemctl enable --now amazon-ssm-agent

    # Apache
    dnf install -y httpd
    systemctl enable --now httpd

    # MySQL client. Amazon Linux 2023 has NO 'mysql' package — dnf install mysql
    # fails with "No match for argument: mysql". The MySQL-compatible client on
    # AL2023 is mariadb105. Found this the hard way in the manual console build.
    dnf install -y mariadb105

    # CloudWatch agent — ships Apache logs off the box so they survive the
    # instance being terminated by the ASG. Without this, logs die with the host.
    dnf install -y amazon-cloudwatch-agent

    cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'CWCONFIG'
    {
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/httpd/access_log",
                "log_group_name": "/aws/ec2/${var.project_name}/apache",
                "log_stream_name": "{instance_id}/access"
              },
              {
                "file_path": "/var/log/httpd/error_log",
                "log_group_name": "/aws/ec2/${var.project_name}/apache",
                "log_stream_name": "{instance_id}/error"
              }
            ]
          }
        }
      }
    }
    CWCONFIG

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -s \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

    # Simple page showing which instance served the request —
    # lets me confirm the ALB is actually load balancing across AZs
    echo "<h1>three-tier app</h1><p>served by: $(hostname -f)</p>" > /var/www/html/index.html
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-app"
      Tier = "app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# Public subnets, wears SG-ALB. Note: security_groups is REQUIRED.
# In the console this was a separate screen from the SG rules — which is
# exactly how SG-App ended up attached here and caused the 502.
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# ---------------------------------------------------------------------------
# Target Group — the list of instances + the health check that decides
# which of them are allowed to receive traffic
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.project_name}-tg"
  }
}

# ---------------------------------------------------------------------------
# Listener — "anything arriving on port 80, forward to the target group"
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# Auto Scaling Group
# Launches instances in PRIVATE subnets, registers them into the target group
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group" "app" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = aws_subnet.private_app[*].id
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
# ---------------------------------------------------------------------------
# Target tracking scaling — keep average CPU at the target
# AWS creates and manages the CloudWatch alarms behind this automatically
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.project_name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.asg_cpu_target
  }
}

# ---------------------------------------------------------------------------
# IAM role for EC2 — the identity the instance wears
# Gives it: Session Manager access + permission to read the DB secret
# No credentials stored on the instance. AWS rotates them automatically.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-ec2-ssm-role"
  }
}

# AWS-managed policy. This is the one whose absence caused
# "AccessDeniedException" in the manual build — the instance had no identity.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Least privilege: read ONLY this one secret. Not all secrets.
resource "aws_iam_role_policy" "read_db_secret" {
  name = "${var.project_name}-read-db-secret"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

# An instance profile is the wrapper that lets an EC2 actually wear the role.
# Roles can't attach to EC2 directly — this is an AWS quirk, not a Terraform one.
resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

# ---------------------------------------------------------------------------
# DB password — generated, never written down
# It lands in Terraform state in plaintext (unavoidable), which is exactly why
# state is in an encrypted private S3 bucket and *.tfstate is gitignored.
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 24
  special = true
  # RDS rejects these characters in a master password
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/db/credentials"
  description             = "RDS master credentials, generated by Terraform"
  recovery_window_in_days = 0 # 0 = delete immediately on destroy (dev only)

  tags = {
    Name = "${var.project_name}-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = 3306
    dbname   = var.db_name
  })
}

# ---------------------------------------------------------------------------
# DB Subnet Group — RDS needs subnets in 2+ AZs for Multi-AZ.
# Trying Multi-AZ with a single-AZ subnet group fails with an unhelpful error.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private_db[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# ---------------------------------------------------------------------------
# RDS MySQL — Multi-AZ, private subnets, SG-DB.
# No public access. No route from the internet exists at all.
# ---------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db"

  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  # Multi-AZ: AWS keeps a synchronous standby in the other AZ and fails over
  # automatically. The endpoint DNS name stays the same — which is why
  # enable_dns_hostnames on the VPC mattered.
  multi_az = true

  publicly_accessible = false

  backup_retention_period = 7
  skip_final_snapshot     = true  # dev only — production would keep a snapshot
  deletion_protection     = false # dev only — production would be true

  tags = {
    Name = "${var.project_name}-db"
  }
}

# ===========================================================================
# OBSERVABILITY
# ===========================================================================

# Current AWS account ID — used to scope IAM policies and name the CloudTrail bucket
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# VPC FLOW LOGS
# Every network connection in the VPC: src, dst, port, ACCEPT or REJECT.
# This is the tool that would have found my 502 in 30 seconds — the ALB's
# health check would have shown REJECT on port 80.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.project_name}/flow-logs"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-flow-logs"
  }
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.project_name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project_name}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL" # ACCEPT, REJECT, and ALL — we want everything
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = {
    Name = "${var.project_name}-vpc-flow-log"
  }
}

# ---------------------------------------------------------------------------
# CLOUDTRAIL — every AWS API call, logged.
# "Who deleted the database?" — without this, you will never know.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # dev only — lets terraform destroy remove a non-empty bucket

  tags = {
    Name = "${var.project_name}-cloudtrail"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CloudTrail needs explicit permission to write into the bucket
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false # single region — cost decision
  enable_log_file_validation    = true  # detects tampering with the log files

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = {
    Name = "${var.project_name}-trail"
  }
}

# ---------------------------------------------------------------------------
# APPLICATION LOGS — ship Apache logs off the instance to CloudWatch.
# Without this, logs die with the instance. The ASG terminates instances
# routinely, so a failed request from 20 minutes ago is unrecoverable.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "apache" {
  name              = "/aws/ec2/${var.project_name}/apache"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-apache-logs"
  }
}

# Let the EC2 role write to CloudWatch Logs
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}



