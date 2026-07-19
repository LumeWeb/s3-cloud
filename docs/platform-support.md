# Platform Support Matrix

Deployment targets for s3-server. All use the same Docker image (`ghcr.io/lumeweb/s3-server:latest`). Per-platform configs are added incrementally as providers are onboarded.

## Self-Hosted Docker

| Platform | Install | Update | Difficulty | Docs |
|---|---|---|---|---|
| Docker Compose | `docker compose up -d` | Sidecar or `docker compose pull && up -d` | Easy | - |

## Cloud VM Marketplaces

| Platform | Install | Update | Difficulty | Docs |
|---|---|---|---|---|
| DigitalOcean 1-Click | Droplet from Marketplace image | Auto-update sidecar | Medium | [deploy/digitalocean/README.md](../deploy/digitalocean/README.md) |
| Vultr 1-Click | VPS from Marketplace image | Auto-update sidecar | Medium | [deploy/vultr/README.md](../deploy/vultr/README.md) |
| AWS EC2 / CloudFormation | EC2 from Marketplace AMI | Auto-update sidecar | Medium | [deploy/aws/README.md](../deploy/aws/README.md) |

## Platform Feature Parity

| Feature | Self-Hosted | DigitalOcean | Vultr | AWS |
|---|---|---|---|---|
| Docker Compose stack | ✅ | ✅ | ✅ | ✅ |
| Auto-update sidecar | Manual | ✅ | ✅ | ✅ |
| HTTPS/S3 domain configuration | Manual | Manual | Manual | Manual |
| CloudFormation deployment | ❌ | ❌ | ❌ | ✅ |
| Firewall configured | Manual | ✅ (ufw) | ✅ (ufw) | ✅ (Security Group + ufw) |

## Notes

- AWS requires the AMI to be published to AWS Marketplace and shared with the AWS Marketplace service account (`679593333241`) before buyers can deploy it. The CloudFormation template in `deploy/aws/cloudformation.template.json` references the AMI ID via an `AWS::EC2::Image::Id` parameter.
- All Marketplace images disable root login and password authentication. Administrative access is via the configured user (`root` on DigitalOcean, `root` on Vultr, or `ubuntu` with optional SSH on AWS).
