# Observability: VPC Flow Logs, CloudTrail and Apache logs in CloudWatch

# Current AWS account ID — used to scope IAM policies and name the CloudTrail bucket
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# VPC FLOW LOGS
# Every network connection in the VPC: src, dst, port, ACCEPT or REJECT.
# This is the tool that would have found my 502 in 30 seconds — the ALB's
# health check would have shown REJECT on port 80.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_158:Encrypted with the AWS managed key. A customer managed KMS key costs extra
  #checkov:skip=CKV_AWS_338:Short retention on purpose to keep the bill down. Production would keep a year
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
  #checkov:skip=CKV_AWS_18:Access logging needs a second bucket just for logs of the log bucket. Overkill here
  #checkov:skip=CKV_AWS_21:Log file validation already detects tampering, and logs expire after 90 days anyway
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage for a test stack
  #checkov:skip=CKV_AWS_145:Encrypted with SSE-S3 (AES256). A customer managed KMS key costs extra
  #checkov:skip=CKV2_AWS_62:Nothing needs to react to new log files
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
  #checkov:skip=CKV_AWS_35:Log files are encrypted by the bucket (SSE-S3). A customer managed KMS key costs extra
  #checkov:skip=CKV_AWS_252:No alerting set up for new log files
  #checkov:skip=CKV2_AWS_10:Sending the trail to CloudWatch Logs costs extra. S3 plus log file validation is enough here
  name                          = "${var.project_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true # all regions, attackers like the ones nobody watches. First copy of management events is free
  enable_log_file_validation    = true # detects tampering with the log files

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
  #checkov:skip=CKV_AWS_158:Encrypted with the AWS managed key. A customer managed KMS key costs extra
  #checkov:skip=CKV_AWS_338:Short retention on purpose to keep the bill down. Production would keep a year
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

# ---------------------------------------------------------------------------
# Expire CloudTrail logs after 90 days. Without this they pile up forever
# and so does the S3 bill.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
