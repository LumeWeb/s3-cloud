#!/bin/bash
# 900-cleanup.sh - DigitalOcean marketplace image cleanup
# Based on DigitalOcean's droplet-1-clicks/common/scripts/900-cleanup.sh
#
# Runs as the final Packer provisioner to prepare the image for submission.

set -o errexit

# Ensure /tmp exists and has the proper permissions
if [[ ! -d /tmp ]]; then
  mkdir /tmp
fi
chmod 1777 /tmp

apt-get -y update
apt-get -y upgrade
rm -rf /tmp/* /var/tmp/*
history -c
cat /dev/null > /root/.bash_history
unset HISTFILE
apt-get -y autoremove
apt-get -y autoclean
find /var/log -mtime -1 -type f -exec truncate -s 0 {} \;
rm -rf /var/log/*.gz /var/log/*.[0-9] /var/log/*-????????
rm -rf /var/lib/cloud/instances/*
rm -f /root/.ssh/authorized_keys /etc/ssh/*key*
touch /etc/ssh/revoked_keys
chmod 600 /etc/ssh/revoked_keys

# Purge the DigitalOcean droplet agent (must not be present in marketplace images)
apt-get --yes purge droplet-agent 2>/dev/null || true

# Securely erase the unused portion of the filesystem
printf "Writing zeros to remaining disk space (may take several minutes)...\n"
dd if=/dev/zero of=/zerofile bs=4096 || true
rm -f /zerofile
sync

cat /dev/null > /var/log/lastlog
cat /dev/null > /var/log/wtmp
