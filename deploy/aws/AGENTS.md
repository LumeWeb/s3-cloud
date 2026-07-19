# deploy/aws/AGENTS.md

AWS Marketplace deployment specifics. See `deploy/AGENTS.md` for the platform-agnostic guide.

## AWS CLI Tools

### aws (AWS CLI v2)

- **Install**: Pre-installed on GitHub Actions `ubuntu-latest` runners. Locally: `pip install awscli` or `apt-get install awscli`.
- **Auth**: Reads `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` env vars. For CI with OIDC, use `aws-actions/configure-aws-credentials@v4` with `role-to-assume`.
- **Region**: Always `us-east-1` for marketplace builds. Set via `AWS_DEFAULT_REGION` or `--region`.
- **Output**: `--output json` for machine parsing; default is `json` in CI.
- **AMI listing**: `aws ec2 describe-images --owners self --filters "Name=name,Values=pinner-s3-aws-*"`
- **AMI deregistration**: `aws ec2 deregister-image --image-id <ami-id>` followed by `aws ec2 delete-snapshot --snapshot-id <snap-id>` (AMIs leave orphaned snapshots that must be deleted separately)
- **Instance IPs**: `aws ec2 describe-instances --instance-ids <id> --query 'Reservations[0].Instances[0].PublicIpAddress' --output text`
- **Instance termination**: `aws ec2 terminate-instances --instance-ids <id>`

### boto3 (Python SDK)

- The prune scripts (`prune-snapshots.py`, `prune-instances.py`) use boto3.
- **Installation**: `pip install boto3` (available on GitHub Actions runners)
- **Auth**: Same env vars as AWS CLI (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`)
- **Pagination**: boto3 paginators handle EC2 `DescribeImages` and `DescribeInstances` pagination automatically

### Marketplace Submission

- **No direct API**: AWS Marketplace does not expose a public API for creating/updating marketplace listings. Submission is manual via the AWS Marketplace Management Portal (AMMP).
- **AMI sharing**: Before submission, the AMI must be shared with the AWS Marketplace scan account (`679593333241`). `submit.py` prints the exact `aws ec2 modify-image-attribute` command.
- **Manual process**: `submit.py` verifies the AMI exists, prints the sharing command, then outputs the AMMP submission steps:
    1. AMMP -> Products -> Add Product
    2. Restrict AMI to your AWS account + scan account
    3. Submit for scanning (takes ~45 minutes)
    4. Complete product listing metadata
    5. Submit for review

## AWS Marketplace Requirements

### Required Scripts (run as final Packer provisioners)

| Script | Source | Purpose |
|--------|--------|---------|
| `shared/scripts/014-ufw-s3.sh` | Shared | Enable ufw firewall (SSH + port 80, Docker FORWARD policy) |
| `shared/scripts/018-force-ssh-logout.sh` | Shared | Block SSH until `001_onboot` completes first-boot setup |
| `scripts/010-aws-credentials.sh` | AWS-specific | Parse EC2 user-data for S3 credentials and auto-update flags (runs before `001_onboot`) |
| `scripts/900-cleanup.sh` | AWS-specific | Clear logs, SSH keys, bash history, zero disk, machine-id, remove authorized keys, fstrim |

### Cloud-init Boot Sequence

Cloud-init executes `per-instance` scripts in lexicographic order:

1. `010-aws-credentials.sh` — Parses EC2 user-data for `s3_access_key`, `s3_secret_key`, `auto_update`. Writes `/opt/s3-server/.env` and `/state/autoupdate.{enabled,disabled}`.
2. `001_onboot` (shared) — Removes SSH lockout, enables ufw, waits for Docker, starts `s3-server.service`.

### Validation

AWS does not provide a standard marketplace validation script. The `validate.sh` script creates a temp EC2 instance from the AMI and performs health checks:

- SSH connectivity (cloud-init completed, SSH lockout removed)
- `s3-server.service` is active
- Docker containers are running
- HTTP healthz endpoint responds with 200
- AWS-specific compliance: `PermitRootLogin no`, `PasswordAuthentication no`, no `ubuntu` authorized keys, no host keys

**SSH wait**: 300s (30 attempts × 10s). AWS instances typically boot within 60-90s.

**Healthcheck**: The Docker healthcheck in `docker-compose.yml` must use `wget -q -O /dev/null` (GET), NOT `wget --spider` (HEAD). The `/_panel/healthz` endpoint is registered as GET-only in Echo, so HEAD returns 405 Method Not Allowed.

### Marketplace Compliance (FAIL = rejection)

- Supported OS: Ubuntu 22.04 LTS (AMI built from official Ubuntu AMI)
- AMI must be HVM, 64-bit, EBS-backed
- Built in `us-east-1`
- cloud-init installed
- No root password set
- No SSH keys in `/root/.ssh/` or `/home/ubuntu/.ssh/`
- Root and user bash history cleared
- No AWS Systems Manager agent or CloudWatch agent pre-installed
- No pending security updates
- Firewall configured (ufw or security groups)
- `PermitRootLogin no` and `PasswordAuthentication no` in `/etc/ssh/sshd_config`
- IMDSv2 compliant (optional but recommended)
- Logs cleared from `/var/log`

## Required Secrets

| Secret | Purpose |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | Packer builds, AWS CLI auth, boto3 auth |
| `AWS_SECRET_ACCESS_KEY` | Packer builds, AWS CLI auth, boto3 auth |
| `CI_BUILD_SSH_KEY` | Private SSH key (ed25519, base64-encoded). Written to `~/.ssh/id_ed25519` on the runner. Used for Packer SSH access and validation instance SSH. |

## AWS-Specific Configuration

### Packer Builder

| Field | Value | Notes |
|-------|-------|-------|
| `source_ami_filter` | Ubuntu 22.04 LTS official AMI | `name: "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"`, `owners: ["099720109477"]` (Canonical) |
| `instance_type` | `t3.small` | 2 vCPU, 2GB RAM. Required for Docker provisioning. |
| `region` | `us-east-1` | AWS Marketplace requires AMIs to be built in us-east-1. |
| `ssh_username` | `ubuntu` | Official Ubuntu AMIs use `ubuntu` user. |
| `ami_name` | `pinner-s3-aws-<timestamp>` | Timestamp from Packer `{{timestamp}}`. |
| `ena_support` | `true` | Required for modern instance types. |
| `sriov_support` | `true` | Required for enhanced networking. |
| `ssh_interface` | `public_ip` | Packer connects via public IP. |

### AWS-Specific Pitfalls

- **AMI deregistration leaves snapshots**: `aws ec2 deregister-image` does NOT delete the underlying EBS snapshot. You must call `aws ec2 delete-snapshot` separately or use `prune-snapshots.py` which handles both.
- **Security group ingress**: The CloudFormation template defaults to `0.0.0.0/0` on port 80 and 22. End users should restrict this. The template documents this in parameter descriptions.
- **No marketplace submit API**: The `submit.py` script verifies the AMI exists and prints the sharing command + AMMP steps. Cannot programmatically submit.
- **IMDSv2**: AWS recommends requiring IMDSv2. The Packer template sets `metadata_options { http_tokens = "optional" }` to allow both v1 and v2 during build. The CloudFormation template sets `MetadataOptions` with `HttpTokens: optional` by default; users can override.
- **AMI copy for other regions**: Marketplace listings can copy the AMI to other regions after us-east-1 submission. The initial build must stay in us-east-1.
- **Prune scripts**: Split into `prune-snapshots.py` (AMIs + snapshots) and `prune-instances.py` (EC2 instances). Each requires `--prefix` (no default). Never combine snapshot and instance deletion.
- **SSH user**: Official Ubuntu AMIs use `ubuntu`, not `root`. The Packer `ssh_username` is `ubuntu`. Cleanup must clear `/home/ubuntu/.ssh/authorized_keys` in addition to `/root/.ssh/`.
- **User-data parsing**: EC2 user-data is plain text. `010-aws-credentials.sh` uses `sed` with strict regex to extract key=value pairs. It never evaluates user-data as shell code (security requirement).
- **CloudFormation template**: `ImageId` uses `AWS::EC2::Image::Id` type (not plain `String`) so the AWS Console presents an AMI picker. Sensitive parameters use `NoEcho: true`.
