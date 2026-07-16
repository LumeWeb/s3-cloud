#!/bin/sh
# 018-force-ssh-logout.sh - Prevent SSH login until first-boot setup completes
# Based on DigitalOcean's droplet-1-clicks/common/scripts/018-force-ssh-logout.sh
#
# The 001_onboot cloud-init script removes this block on first boot.

cat >> /etc/ssh/sshd_config <<EOM
Match User root
        ForceCommand echo "Please wait while we get your droplet ready..."
EOM
