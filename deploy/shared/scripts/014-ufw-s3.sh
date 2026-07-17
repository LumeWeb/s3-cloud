#!/bin/sh
# 014-ufw-s3.sh - Configure ufw firewall for S3 Server
# Provider-agnostic: ufw works the same across all Ubuntu/Debian-based vendors.

# Docker needs FORWARD policy set to ACCEPT for container networking
sed -e 's|DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|g' \
    -i /etc/default/ufw

ufw limit ssh
ufw allow 80/tcp

ufw --force enable
