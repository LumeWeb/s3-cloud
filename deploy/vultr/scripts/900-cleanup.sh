#!/bin/bash
# 900-cleanup.sh - Vultr marketplace image cleanup
#
# Runs as the final Packer provisioner to prepare the image for submission.
# Follows Vultr's official clean_system() checklist from
# https://github.com/vultr/vultr-marketplace/blob/main/helper-scripts/vultr-helper.sh

set -o errexit

# Ensure /tmp exists and has the proper permissions
if [[ ! -d /tmp ]]; then
  mkdir /tmp
fi
chmod 1777 /tmp

# Wait for any apt/dpkg locks to be released (unattended-upgrades may
# still be running after cloud-init completes)
echo "Waiting for apt/dpkg locks to be released..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
  sleep 5
done

# Update and clean packages
apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
apt-get -y autoremove
apt-get -y autoclean

# Set Vultr kernel option (required for Bare Metal, best practice for VPS)
if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub; then
    sed -i -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ vultr"/' /etc/default/grub
else
    sed -i -e '/^GRUB_CMDLINE_LINUX=/ s/"$/ vultr"/' /etc/default/grub
fi
update-grub

# Clean temporary files
rm -rf /tmp/* /var/tmp/*

# Remove SSH keys
rm -f /root/.ssh/authorized_keys /etc/ssh/*key*
touch /etc/ssh/revoked_keys
chmod 600 /etc/ssh/revoked_keys

# Clean logs
find /var/log -mtime -1 -type f -exec truncate -s 0 {} \;
rm -rf /var/log/*.gz /var/log/*.[0-9] /var/log/*-????????
: > /var/log/auth.log
: > /var/log/lastlog
: > /var/log/wtmp

# Clean cloud-init instance data
rm -rf /var/lib/cloud/instances/*

# Clean bash history
history -c
: > /root/.bash_history
unset HISTFILE

# Remove systemd random-seed (ensures fresh entropy per deployment)
rm -f /var/lib/systemd/random-seed

# Zero machine-id (ensures unique ID per deployment)
: > /etc/machine-id
[[ -e /var/lib/dbus/machine-id ]] && : > /var/lib/dbus/machine-id

# Securely erase the unused portion of the filesystem (enables snapshot compression)
printf "Writing zeros to remaining disk space (may take several minutes)...\n"
dd if=/dev/zero of=/zerofile bs=4096 || true
rm -f /zerofile
sync

# Trim SSD (further improves snapshot compression)
fstrim / || true
