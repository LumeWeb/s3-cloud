# AWS Marketplace Listing

## App Name
Pinner S3 Server

## Short Description
Self-hosted, private S3-compatible object storage with automatic updates on AWS.

## Description
Pinner S3 Server is a lightweight, self-hosted S3-compatible object storage service that runs in Docker on Amazon EC2. It includes a built-in update sidecar that automatically checks for and applies new container image releases. Launch the AMI or deploy the CloudFormation template to start managing your own object storage.

### Features
- S3-compatible API on port 80
- Automatic container image updates (ON by default)
- Docker Compose-based deployment for easy management
- Health checks and auto-restart on failure
- CloudFormation template with security-group guidance
- IPv4 and IPv6 ready ( listening port is bound for both)

### Getting Started
1. Subscribe to the product in AWS Marketplace and launch the CloudFormation stack (or AMI directly).
2. The service starts automatically on first boot and pulls the latest container images.
3. Access the S3-compatible API at `http://your-ec2-ip/`.
4. Configure credentials by passing `s3_access_key` and `s3_secret_key` as EC2 user-data or by editing `/opt/s3-server/.env`.

### Support
For documentation and support, visit https://pinner.xyz.

## Product Categories
- Storage
- Cloud Infrastructure
- Developer Tools
