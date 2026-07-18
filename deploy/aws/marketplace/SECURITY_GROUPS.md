# Recommended Security Group Rules

## Inbound

| Protocol | Port | Source | Purpose |
|----------|------|--------|---------|
| TCP | 80 | `AllowedAppCIDR` parameter (default `0.0.0.0/0`) | S3-compatible HTTP API |
| TCP | 22 | `AllowedSSHCIDR` parameter (default empty/disabled) | Administrative SSH access |

## Outbound

| Protocol | Port | Destination | Purpose |
|----------|------|-------------|---------|
| All | All | `0.0.0.0/0` | Docker image pulls, apt updates, GHCR polling |

## Recommendation

Restrict `AllowedAppCIDR` to your trusted IP ranges or corporate network. Leave `AllowedSSHCIDR` blank and use AWS Systems Manager Session Manager for administrative access.
