# Pinner.xyz S3 Server — AWS Marketplace Usage Instructions

## What is deployed

Pinner.xyz S3 Server is a private, zero-knowledge, self-hosted S3-compatible object storage server. The AWS Marketplace listing deploys a single Amazon EC2 instance from a pre-built AMI. The AMI includes Docker, Docker Compose, and an auto-update sidecar.

## Deployment requirements

- An existing VPC and subnet in the target AWS Region.
- The Marketplace AMI ID for your Region (supplied by the listing).
- (Optional) S3-compatible access credentials. If provided, they are passed through EC2 user-data and written to `/opt/s3-server/.env` on first boot.

## Post-deployment steps

1. After the CloudFormation stack reaches `CREATE_COMPLETE`, open the **Outputs** tab and copy the `S3ServerURL` value (`http://<ElasticIP>/`).
2. Allow 1–2 minutes for the Docker containers to pull and start on first boot.
3. Verify the service: `systemctl status s3-server`.
4. Access the S3-compatible API on port **80**.

## Auto-update

The deployment includes an optional auto-update sidecar that polls `ghcr.io/lumeweb/s3-server:latest` every 6 hours and recreates the `s3-server` container when a new image digest is available. This keeps the instance current without manual intervention. The sidecar is enabled by default and can be disabled at launch via the `AutoUpdate` parameter or at runtime by creating `/state/autoupdate.disabled`.

## External dependencies

This product requires an internet connection to deploy properly. The following are downloaded or accessed on deployment and on an ongoing basis:

- Docker Engine and Docker Compose plugin from official Docker repositories.
- Container images from `ghcr.io/lumeweb/s3-server:latest` and `ghcr.io/lumeweb/s3-server-updater:latest`.

## Security

- SSH access is disabled by default. To enable SSH, provide a trusted CIDR in the `AllowedSSHCIDR` parameter. We recommend using AWS Systems Manager Session Manager instead.
- The security group allows inbound TCP 80 from the CIDR specified in `AllowedAppCIDR`. Restrict this to your trusted network in production.
- S3 credentials are optional. If supplied, they are marked `NoEcho` in CloudFormation and are not returned in stack outputs.

## Support

For documentation, issues, and source code, visit https://github.com/LumeWeb/s3-server.
