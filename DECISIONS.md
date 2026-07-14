# Build notes — decisions, tradeoffs, problems

## Decision 1 — Remote state on S3 instead of local state
Local state works for one person on one laptop. It fails the moment a CI
pipeline or a second person runs Terraform — two concurrent applies silently
overwrite each other's record of what exists, and a lost state file means AWS
resources Terraform can no longer destroy.

Tradeoff accepted: the S3 bucket has to be created manually before Terraform
can run at all — Terraform can't create the bucket that holds its own state.
That's a one-time manual step I accepted because the failure it prevents is
unrecoverable.

Practice demonstrated: state management.

## Decision 2 — S3 native locking (use_lockfile) instead of a DynamoDB table
Every tutorial says create a DynamoDB table for state locking. I did — then
Terraform 1.15 warned me `dynamodb_table` is deprecated. Newer S3 supports
conditional writes natively, so the separate table isn't needed.

I switched. One less manually-created resource, one less thing to drift.

Tradeoff: most existing Terraform codebases still use DynamoDB, so I made
sure I understand both. If I join a team running the older pattern, I know
what it's doing and why it exists.

## Decision 3 — Flat file structure, not modules
Modules exist for reuse across environments. This is one environment, built
once. Modules would add indirection for zero benefit here.

Tradeoff: if I add staging later, I'd have to refactor. Chose readability now
over reuse I don't need yet.

## Decision 4 — default_tags on the provider
Every resource Terraform creates is auto-tagged ManagedBy=Terraform. In my
manual console build I had untagged resources scattered with no way to tell
what belonged to what. Now everything is traceable with one console filter.

## Problem 1 (real, hit during build) — wrong OS binary
Downloaded the darwin (macOS) build of Terraform by mistake — the file had no
.exe extension and bash kept saying "command not found". Then found the
correct Windows binary was nested inside a subfolder in System32, which isn't
on PATH. Moved terraform.exe directly into System32. Fixed.

## Problem 2 (real, hit during build) — deprecated dynamodb_table
terraform init succeeded but warned that dynamodb_table is deprecated in
favour of use_lockfile. Switched to native S3 locking and re-ran with
`terraform init -reconfigure`. Clean.

## Setup so far
- Terraform v1.15.8
- AWS provider v5.100.0
- State: s3://murali-tfstate-9999/three-tier/terraform.tfstate
- Locking: S3 native (use_lockfile), encrypted at rest

## Real numbers (captured during build)
- Networking layer: 18 AWS resources managed as code
  (1 VPC, 1 IGW, 6 subnets, 1 EIP, 1 NAT GW, 2 route tables, 6 associations)
- Verified via `terraform plan` before first apply — count matched expected exactly

## Real numbers (captured during build)

### Networking layer
- 18 AWS resources managed as code
  (1 VPC, 1 IGW, 6 subnets, 1 EIP, 1 NAT GW, 2 route tables, 6 RT associations)
- `terraform plan` predicted 18 — matched the manual count exactly before any apply
- Apply time: 2 min 39 sec (NAT Gateway is the slow part — ~90s of that)

## Decision 5 — Security groups reference each other, not IP ranges

SG-App's ingress rule points at SG-ALB by reference, not by CIDR:

    security_groups = [aws_security_group.alb.id]

Not an IP range. An identity. It means "allow traffic from whatever is wearing
the SG-ALB badge."

Why this matters: the ALB's IP changes as AWS scales it and moves it between
AZs. A CIDR-based rule would silently break. A security group reference never
does. And every EC2 the ASG launches automatically gets SG-App, so it's covered
the moment it exists — no rule updates needed.

## The 502 bug — and why it can't recur

In the manual console build, I let the ASG auto-create the load balancer. AWS
attached SG-App to the ALB instead of SG-ALB. The security chain broke, every
target went Unhealthy, and the ALB returned 502.

I spent time checking the wrong things first — Apache was running fine, route
tables were correct, SG-App's rules were correct. The break was in which SG was
*attached* to the ALB, which is a completely separate screen in the console from
where you write the SG rules. Nothing connects the two.

In Terraform the wiring is in one place:

    resource "aws_security_group" "app" {
      ingress {
        security_groups = [aws_security_group.alb.id]   # only the ALB may talk to me
      }
    }

    resource "aws_lb" "main" {
      security_groups = [aws_security_group.alb.id]     # the ALB declares what it wears
    }

The ALB cannot exist without naming its security group — it's a required
argument. If I attached SG-App to the ALB instead, SG-App's own ingress rule
would then be pointing at an SG that nothing is wearing. The chain visibly does
not connect, in the code, before anything is deployed.

It isn't prevented by a validation rule. It's prevented because the wiring is
written down in one place instead of being implicit across three console screens.

## The mariadb105 fix is now permanent

In the manual build, `dnf install mysql` failed on the EC2 with:
"No match for argument: mysql". Tried `yum install mysql` and
`mysql80-community-release` too — both failed. The instance was running Amazon
Linux 2023, not AL2. AL2023 has no `mysql` package; the MySQL-compatible client
is `mariadb105`.

That fix is now inside the launch template's user data. Every instance the ASG
ever launches gets the correct package on first boot. Nobody — including future
me — has to rediscover it.

Also added `set -e` to the user data script. Without it, if a package install
fails, the script continues and the instance boots "successfully" with no web
server — and the ALB health check fails for no visible reason. `set -e` makes
the failure loud instead of silent.

## Decision 6 — AMI looked up, not hardcoded

Used a `data "aws_ami"` block to query for the latest Amazon Linux 2023 image
rather than pasting an AMI ID. Hardcoded AMI IDs go stale (Amazon publishes new
ones for every patch) and differ per region.

Tradeoff: `most_recent = true` means the AMI can change between applies, which
could in theory introduce an untested image. For production I'd pin to a
specific, tested AMI ID and update it deliberately. For this project I chose
always-current over always-identical.

## Observation — default_tags paid off immediately

After the first apply I checked the console and briefly saw 2 VPCs, 12 subnets,
2 IGWs — my old manually-built VPC was still visible alongside the Terraform one.
The `ManagedBy = Terraform` tag was the only reliable way to tell which resources
belonged to which build. In the manual build, tagging was inconsistent because I
had to remember it every single time.

## Real numbers so far

- Networking layer: 18 resources (1 VPC, 1 IGW, 6 subnets, 1 EIP, 1 NAT GW,
  2 route tables, 6 RT associations)
- Security groups: 3 resources
- Running total: 21 AWS resources managed as code
- Networking apply time: 2 min 39 sec (NAT Gateway ~90s of that)
- `terraform plan` predicted 18 for networking — matched my hand count exactly
  before any apply ran

## Real problem hit — browser forced HTTPS
Targets came up healthy on the first apply, but the ALB URL timed out in the
browser. The browser had silently upgraded the URL to https:// — my listener is
HTTP:80 only, and SG-ALB only opens port 80, so nothing was listening on 443
and the connection just hung with ERR_TIMED_OUT.

Not an infrastructure bug — a browser default. But it's exactly why production
would need an HTTPS listener on 443 with an ACM certificate, and a redirect from
80 to 443. I left it HTTP-only here: adding TLS needs a domain name I'd have to
register, which is outside the scope of this build.

Tradeoff accepted, and I know exactly what's missing and why.

### Verified — app live on first apply
ALB URL served the page. Instance shown: ip-10-0-11-154 — an EC2 in the private
app subnet (10.0.11.0/24) with no public IP, reachable only through the ALB.

Both targets were healthy on the FIRST apply. No 502, no debugging.

In the console build this is exactly where it broke — all targets Unhealthy,
and I lost time checking Apache, route tables and SG-App's rules before finding
the real cause: the ALB had SG-App attached instead of SG-ALB.

Same architecture, same services, different outcome. Not because Terraform is
magic, but because the SG wiring is declared in one file where a mismatch is
visible before deploy instead of after.

## Real problem hit — browser forced HTTPS
The ALB URL timed out at first (ERR_TIMED_OUT). The browser had silently
upgraded it to https:// — my listener is HTTP:80 only and SG-ALB only opens
port 80, so nothing was listening on 443.

Not an infrastructure bug, a browser default. But it's exactly why production
needs an HTTPS listener on 443 with an ACM cert and a 80→443 redirect. I left it
HTTP-only: TLS needs a registered domain, which is outside this build's scope.
Known gap, deliberate.

## Real problem hit — DBSubnetGroupAlreadyExists

`terraform apply` failed partway through:

    Error: creating RDS DB Subnet Group (three-tier-db-subnet-group):
    DBSubnetGroupAlreadyExists

A DB subnet group with that name already existed in the account — left over from
my earlier manual console build. It existed in AWS but was in nobody's state
file. An orphaned resource.

Two options: delete the orphan and let Terraform create its own, or use
`terraform import` to bring the existing one under Terraform's management.

I deleted it — I wanted a stack fully owned by Terraform, and the orphan had no
reason to survive. But `terraform import` is the right answer when you can't
delete something (a production DB, for example), and it's how you adopt existing
infrastructure without recreating it.

Also learned: Terraform doesn't roll back on failure. The 8 resources created
before the error stayed created and were recorded in state. Re-running apply
picked up exactly where it stopped and only created what was missing.

### Data + access layer
- 12 resources (IAM role, 2 policies, instance profile, random_password,
  Secrets Manager secret + version, DB subnet group, RDS instance)
- RDS Multi-AZ alone took 16m22s to provision — by far the slowest resource
  in the build. AWS creates the primary, then the standby, then syncs them.
- TOTAL: 36 AWS resources managed as code

### Full stack timings (real, measured)
- Networking (18 resources):        2m39s
- Security + compute (9 resources): 3m10s  (ALB alone was 3m01s)
- Data + access (12 resources):     16m32s (RDS Multi-AZ was 16m22s)

## Real problem hit — launch template changed, running instances didn't

After adding the IAM instance profile to the launch template, Terraform reported
success. But Session Manager still failed:

    DHMC is not enabled and IAM instance profile is not attached
    Ping status: Offline

The cause: a launch template is only a blueprint. Changing it affects instances
created FROM THAT POINT ON. The two instances already running were launched from
the previous template version and still had no IAM role.

Terraform's "Modifications complete" was accurate — it did update the template.
But nothing told the ASG to cycle its instances onto the new version.

Fix: added an `instance_refresh` block to the ASG so a launch template change
triggers a rolling replacement automatically:

    instance_refresh {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 50
      }
    }

min_healthy_percentage = 50 keeps half the fleet serving during the swap, so
there's no downtime.

This is the same class of bug as the AccessDeniedException from the manual build
— an instance with no identity — but a completely different cause. In the manual
build I'd forgotten to attach the role. Here the role was defined correctly, and
the running instances just hadn't picked it up yet. "Terraform said it worked" is
not the same as "the running fleet reflects it."

## Real problem hit — SSM Agent missing (bad AMI filter)

Session Manager showed "Ping status: Offline" and "Last ping time: —" on a
freshly launched instance. The IAM role WAS attached this time, so it wasn't the
identity problem from the manual build.

Pulled the EC2 system log. The user data script had completed cleanly — Apache
installed, mariadb105 installed, zero errors, cloud-init finished in 44 seconds.
So the instance had working outbound internet through the NAT Gateway.

Then grepped the log for "ssm". Nothing. Not starting, not failing — the SSM
Agent simply wasn't on the box.

Cause: my AMI data source filter was too loose:

    values = ["al2023-ami-*-x86_64"]

That wildcard also matches al2023-ami-MINIMAL-*, and the minimal AL2023 variant
ships without the SSM Agent. With most_recent = true, Terraform silently picked
a minimal image.

Two fixes:
1. Tightened the filter to al2023-ami-2023.*-kernel-6.1-x86_64 — standard variant only
2. Explicitly installed amazon-ssm-agent in user data, so secure access doesn't
   depend on which AMI variant the data source happens to return

This is exactly the downside of the `most_recent = true` tradeoff I'd already
noted: always-current means the image can change under you. In production I'd
pin a specific tested AMI ID.

The debugging path is the point: the system log said the script succeeded, and
the absence of any SSM lines is what identified the cause. Nothing errored —
the agent was just never there.

## Verified — full stack, end to end

Connected to a private EC2 via Session Manager. No SSH key. No .pem file. No
port 22 open in any security group. No bastion host. No public IP on the
instance. The SSM Agent makes an OUTBOUND connection to AWS and the session is
relayed back — I never connect *to* the box.

From inside it, read the DB credentials from Secrets Manager. The instance has
zero stored credentials — its IAM role gives it temporary, auto-rotating creds,
scoped to exactly one secret.

Then connected to RDS:

    mysql -h three-tier-db.cu5ou4mmuxe2.us-east-1.rds.amazonaws.com -u admin -p
    Welcome to the MariaDB monitor.
    Server version: 8.4.9

    SHOW DATABASES;
    appdb, information_schema, mysql, performance_schema, sys

One test, six things proven: SSM works, IAM least-privilege works, SG-App→SG-DB
chain works, mariadb105 was already installed, RDS is up, NAT Gateway is routing.

The mysql client being there without me doing anything is the point. In the
manual build I hit "No match for argument: mysql" and lost time working out that
AL2023 needs mariadb105. That fix now lives in the launch template. I solved it
once, permanently.

## Security posture

**What's enforced:**
- 3-layer security group chain. The DB accepts traffic only from the app tier,
  which accepts traffic only from the ALB. No SG references a CIDR except the ALB.
- RDS in private subnets, publicly_accessible = false. There is no route from
  the internet to the database — not by firewall rule, by topology.
- No port 22 open anywhere. Access is via Session Manager, which uses an
  outbound connection from the instance. There is no inbound attack surface.
- DB password generated by Terraform, stored in Secrets Manager. Never in code,
  never in the repo. The app reads it via an IAM role scoped to that one secret.
- Terraform state is encrypted in S3 and gitignored — because state contains the
  password in plaintext and there's no way around that.
- VPC Flow Logs and CloudTrail enabled — network forensics and API audit trail.

**What's missing, and why:**
- No HTTPS. The ALB is HTTP-only. TLS needs a registered domain, which is
  outside this build's scope. Traffic to the ALB is plaintext.
- No secret rotation. Secrets Manager supports it (~$0.40/month); I didn't
  enable it. A leaked password stays valid indefinitely.
- No GuardDuty or AWS Config. Both would cost more than the rest of this build
  combined at this scale.
- My admin IAM user can read the DB secret. In production, human engineers
  shouldn't be able to read prod credentials — only the app's role should.
  IAM database authentication would remove the password entirely.

## Observability — the thing that would have found my 502 in 30 seconds

Apache access logs, shipped to CloudWatch:

    10.0.2.226 - - "GET / HTTP/1.1" 403 191 "ELB-HealthChecker/2.0"
    10.0.1.190 - - "GET / HTTP/1.1" 403 191 "ELB-HealthChecker/2.0"
    10.0.2.226 - - "GET / HTTP/1.1" 200 69  "ELB-HealthChecker/2.0"
    10.0.1.190 - - "GET / HTTP/1.1" 200 69  "ELB-HealthChecker/2.0"

You can watch the ALB health-check the instance from both public subnets
(10.0.1.x and 10.0.2.x), get a 403 while user data is still running, then flip
to 200 once index.html is written. That's the health_check_grace_period doing
its job, visible in real logs.

In the manual build, these lines would not have existed AT ALL. The wrong SG was
attached to the ALB, so the health check never reached the instance — Apache's
access log would have been empty.

That's the diagnostic:
- No log lines       -> health check isn't reaching the box -> security group problem
- 4xx/5xx lines      -> it reaches the box, the app is broken
- 200 lines          -> working

I had no logging in the manual build, so I couldn't tell those apart. I checked
Apache, then route tables, then SG rules, one at a time. With this in place it's
a 30-second answer instead of a 30-minute hunt.

## The 403s in the Apache log are expected — and they justify the grace period

The first two ALB health checks return 403, then flip to 200:

    "GET / HTTP/1.1" 403 191 "ELB-HealthChecker/2.0"
    "GET / HTTP/1.1" 200 69  "ELB-HealthChecker/2.0"

Apache starts partway through the user data script, but index.html isn't written
until the last line. In between, /var/www/html is empty — Apache returns 403
(not 404, because directory listing is disabled by default).

This is exactly what health_check_grace_period = 300 protects against. Without
it, the ASG would see the 403, mark the instance unhealthy, terminate it, and
launch a replacement — which would also 403 while booting and also get killed.
An infinite churn loop.

I could avoid the 403 by writing index.html before starting Apache. I didn't —
dnf update timing varies, and the grace period is the correct answer regardless.
Fixing the symptom would hide the real need.

## Reproducibility — measured, not claimed

    terraform destroy   ->  Destroy complete! Resources: 47 destroyed.
    terraform apply     ->  Apply complete! Resources: 47 added.

Destroy: ~13 min (RDS deletion alone was 6m30s)
Rebuild: 15 min 36 sec (RDS Multi-AZ alone was 14m52s of it)

Everything came back: VPC, 6 subnets across 2 AZs, NAT gateway, 3-layer SG
chain, ALB, ASG (min 2 / max 4), RDS MySQL 8.4 Multi-AZ, IAM roles, Secrets
Manager, VPC Flow Logs, CloudTrail, CloudWatch agent.

New AWS resource IDs, identical configuration:
  ALB before:  three-tier-alb-1816193923...
  ALB after:   three-tier-alb-528708595...
  VPC before:  vpc-063bdc222855d57f7
  VPC after:   vpc-0ee44836ee148902c

Zero console clicks. Zero manual steps. Zero rediscovered bugs.

The mariadb105 fix, the SSM agent install, the SG chain, the IAM instance
profile — every problem I'd already solved stayed solved. I did not debug a
single one of them again.

And nobody typed a database password. random_password generated a new one,
handed it to RDS, and wrote it to Secrets Manager. The app reads it via its
IAM role. I don't know what it is and I don't need to.

## Final numbers

- 47 AWS resources managed as code
- Full teardown:  ~13 min
- Full rebuild:   15 min 36 sec
- 5 real problems hit and fixed permanently:
    1. ALB 502 — wrong SG attached (from the manual build)
    2. mariadb105 — AL2023 has no mysql package (from the manual build)
    3. Orphaned DB subnet group — existed in AWS, in no state file
    4. Launch template changed, running instances didn't
    5. SSM agent missing — AMI filter too loose, pulled the minimal image

## CI/CD — deliberately not built

No pipeline. I run terraform apply from my laptop. In a real team that's wrong —
apply should run in CI after a human reviews the plan output on a pull request.

But auto-applying infrastructure on a push is worse than not having a pipeline
at all. A malformed variable can destroy an RDS instance with nobody having read
the diff. Application code rolls back in minutes; a deleted database does not.

The right pattern is: PR opens -> CI runs fmt/validate/plan -> plan is posted as
a comment -> a human reads it -> apply runs after approval. The human gate is the
point, not an obstacle.

I know this is the biggest gap in the project.