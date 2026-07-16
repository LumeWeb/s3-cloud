#!/bin/sh
# 020-application-tag.sh - Write application metadata for DigitalOcean
# Based on DigitalOcean's droplet-1-clicks/common/scripts/020-application-tag.sh
#
# application_name and application_version are injected by Packer environment_vars.

# shellcheck disable=SC2154
build_date=$(date +%Y-%m-%d)
distro="$(lsb_release -s -i)"
distro_release="$(lsb_release -s -r)"
distro_codename="$(lsb_release -s -c)"
distro_arch="$(uname -m)"

mkdir -p /var/lib/digitalocean

cat >> /var/lib/digitalocean/application.info <<EOM
application_name="${application_name}"
build_date="${build_date}"
distro="${distro}"
distro_release="${distro_release}"
distro_codename="${distro_codename}"
distro_arch="${distro_arch}"
application_version="${application_version}"
EOM
