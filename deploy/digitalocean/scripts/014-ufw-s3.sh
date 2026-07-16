#!/bin/sh
# 014-ufw-s3.sh - Configure ufw firewall for S3 Server
# Adapted from DigitalOcean's common/scripts/014-ufw-docker.sh

# Docker needs FORWARD policy set to ACCEPT for container networking
sed -e 's|DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|g' \
    -i /etc/default/ufw

ufw limit ssh
ufw allow 80/tcp

ufw --force enable
