# Pinner S3 Server: AWS Marketplace Deployment

Deploy [S3 Server](https://github.com/lumeweb/s3-server) on AWS EC2 via CloudFormation using a pre-built Packer AMI with auto-update sidecar.

## What This Deploys

| Component | Description |
|-----------|-------------|
| **s3-server** | Object storage server (`ghcr.io/lumeweb/s3-server:latest`) on port **80** |
| **updater** | Sidecar container (`ghcr.io/lumeweb/s3-server-updater:latest`) that polls GHCR for new images every 6 hours |
| **Root EBS Volume** | Single gp3 root volume (`/dev/sda1`, default 50GB) holds OS, Docker images, and `/data` |
| **Elastic IP** | Static public IP assigned to the instance |
| **Security Group** | Inbound: TCP 80 (app), optional TCP 22 (SSH); Outbound: all |
| **Systemd** | `s3-server.service` starts Docker Compose on boot |

## Requirements

- **AWS account** with VPC and subnet access
- Packer AMI published to AWS Marketplace
- IAM permissions: EC2, EBS, Elastic IP, CloudFormation, Security Groups

## Quick Start

### Option A: CloudFormation Stack (Recommended)

1. Go to **AWS CloudFormation Console** -> **Create Stack** -> **With new resources (standard)**
2. Upload `deploy/aws/cloudformation.template.json` or reference it via S3 URL
3. Fill parameters:
   - **VpcId**: Your VPC ID
   - **SubnetId**: Target subnet for the instance
   - **S3ServerAMI**: The S3 Server marketplace AMI ID (region-specific)
   - **InstanceType**: `t3.small` (default) or higher
   - **VolumeSize**: 50 (default, min 20GB)
   - **AutoUpdate**: `true` (default) or `false`
   - **AllowedAppCIDR**: `0.0.0.0/0` (default) or restrict
   - **AllowedSSHCIDR**: Your trusted IP range, or leave blank to disable SSH
   - **S3AccessKey / S3SecretKey**: Optional S3 credentials (passed via EC2 user-data)
4. Click **Create Stack**
5. Check the **Outputs** tab for `S3ServerURL` (e.g., `http://x.x.x.x/`)

### Option B: Build the AMI with Packer

```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
cd /path/to/s3-cloud
cd deploy/aws
make build
```

This builds `pinner-s3-aws-<timestamp>` based on Ubuntu 22.04 LTS.

## Persistent Storage

The CloudFormation template uses a single gp3 root volume (`/dev/sda1`, default 50GB, min 20GB) for the OS, Docker images, and the `/data` directory mounted into the s3-server container.

To resize: update the `VolumeSize` parameter and run a CloudFormation stack update, then extend the filesystem with `growpart`/`resize2fs` inside the instance.

## Auto-Update

Auto-update is **enabled by default** when `AutoUpdate=true`. The updater sidecar container checks GHCR for new `:latest` image digests every 6 hours and recreates the `s3-server` container when a new digest is found.

The EC2 user-data passes `auto_update=true` or `auto_update=false` to the per-instance provisioning script (`scripts/001_provision.sh`), which sets the appropriate flag file in `/state` on first boot.

### Flag-File API

| File | Purpose |
|------|---------|
| `/state/autoupdate.enabled` | Present = auto-update ON |
| `/state/autoupdate.disabled` | Present = auto-update OFF (takes precedence) |
| `/state/update.trigger` | Force update check on next cycle |
| `/state/updater.log` | Append-only updater log |
| `/state/last-digest` | Last applied image digest |

### Disable Auto-Update

```bash
ssh ubuntu@<instance-ip>
sudo touch /state/autoupdate.disabled
sudo docker compose -f /opt/s3-server/docker-compose.yml restart
```

### Force a Manual Update

```bash
sudo touch /state/update.trigger
```

## Files

| File | Purpose |
|------|---------|
| `cloudformation.template.json` | CloudFormation stack template for EC2 deployment |
| `template.pkr.hcl` | Packer template to build the AWS Marketplace AMI (x86-64) |
| `scripts/001_provision.sh` | Cloud-init per-instance script: reads EC2 user-data for S3 credentials and auto-update config |
| `scripts/900-cleanup.sh` | Final Packer provisioner: hardens and cleans the AMI |
| `scripts/validate.sh` | Creates a temp EC2 instance from the AMI and runs compliance/health checks |
| `scripts/prune-snapshots.py` | Deregisters old CI AMIs and deletes their snapshots |
| `scripts/prune-instances.py` | Terminates old CI EC2 instances |
| `submit.py` | Prints AMI ID and AWS Marketplace sharing instructions |
| `marketplace/` | Submission assets required by AWS Marketplace |
| `README.md` | This file |

## License

This deployment configuration is provided under the MIT License.
The S3 Server itself is licensed separately - see the [upstream repo](https://github.com/lumeweb/s3-server).
