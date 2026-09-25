# Compute: EC2 launch template, load balancer, Auto Scaling and the EC2 IAM role

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

  # IMDSv2 only. With v1, an SSRF bug in the app could read the instance
  # role's credentials with one plain GET request. Nothing in the user data
  # calls the metadata endpoint directly, and the SSM + CloudWatch agents
  # both support v2, so this doesn't break anything.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
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
  #checkov:skip=CKV_AWS_91:ALB access logs need another S3 bucket. VPC Flow Logs and Apache logs already cover debugging
  #checkov:skip=CKV_AWS_150:Deletion protection would block terraform destroy, which I run after every test (Known gaps)
  #checkov:skip=CKV2_AWS_20:Redirect to HTTPS needs a certificate. No domain name so no ACM certificate yet. HTTPS is the first item in Known gaps
  #checkov:skip=CKV2_AWS_28:WAF costs more than the rest of the stack at this scale (Known gaps)
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Drop requests with malformed headers instead of passing them to Apache
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# ---------------------------------------------------------------------------
# Target Group — the list of instances + the health check that decides
# which of them are allowed to receive traffic
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:ALB to EC2 traffic stays inside private subnets. No domain name so no ACM certificate yet. HTTPS is the first item in Known gaps
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
  #checkov:skip=CKV_AWS_2:No domain name so no ACM certificate yet. HTTPS is the first item in Known gaps
  #checkov:skip=CKV_AWS_103:TLS policy only applies to an HTTPS listener. No domain name so no ACM certificate yet. HTTPS is the first item in Known gaps
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
