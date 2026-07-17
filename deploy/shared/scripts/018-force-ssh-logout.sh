#!/bin/sh
# 018-force-ssh-logout.sh - Prevent SSH login until first-boot setup completes
# Provider-agnostic: works on any cloud that supports cloud-init.
#
# The 001_onboot cloud-init script removes this block on first boot.

cat >> /etc/ssh/sshd_config <<EOM
Match User root
        ForceCommand echo "Please wait while we get your server ready..."
EOM
