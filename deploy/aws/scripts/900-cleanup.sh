#!/bin/bash
# 900-cleanup.sh - AWS Marketplace AMI cleanup
# Runs as the final Packer provisioner to prepare the image for submission.

set -o errexit

# Ensure /tmp exists and has the proper permissions
if [[ ! -d /tmp ]]; then
  mkdir /tmp
fi
chmod 1777 /tmp

# Wait for any apt/dpkg locks to be released
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||       fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done

apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade
apt-get -y autoremove
apt-get -y autoclean

# Clean temporary files
rm -rf /tmp/* /var/tmp/*

# Remove SSH keys and host keys (regenerated on first boot)
rm -f /root/.ssh/authorized_keys /etc/ssh/*key*
touch /etc/ssh/revoked_keys
chmod 600 /etc/ssh/revoked_keys

# Clean logs
find /var/log -mtime -1 -type f -exec truncate -s 0 {} \;
rm -rf /var/log/*.gz /var/log/*.[0-9] /var/log/*-????????
: > /var/log/lastlog
: > /var/log/wtmp

# Clean cloud-init instance data and logs, but preserve seed for next boot
# --seed forces cloud-init to re-run all modules on the next boot (fresh instance)
cloud-init clean --logs --seed 2>/dev/null || true
rm -rf /var/lib/cloud/instances/*

# Clean bash history
history -c
: > /root/.bash_history
unset HISTFILE

# Remove systemd random-seed and machine-id (regenerated on first boot)
rm -f /var/lib/systemd/random-seed
: > /etc/machine-id
[[ -e /var/lib/dbus/machine-id ]] && : > /var/lib/dbus/machine-id

# Securely erase the unused portion of the filesystem
printf "Writing zeros to remaining disk space (may take several minutes)...\n"
dd if=/dev/zero of=/zerofile bs=4096 || true
rm -f /zerofile
sync

fstrim / || true
