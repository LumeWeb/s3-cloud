packer {
  required_plugins {
    vultr = {
      source  = "github.com/vultr/vultr"
      version = ">= 2.5.0"
    }
  }
}

variable "vultr_api_key" {
  type      = string
  default   = env("VULTR_API_KEY")
  sensitive = true
}

variable "vultr_region" {
  type    = string
  default = "ewr"
}

variable "application_name" {
  type    = string
  default = "S3 Server"
}

variable "application_version" {
  type    = string
  default = "1.0.0"
}

variable "snapshot_prefix" {
  type    = string
  default = "pinner-s3-vultr-"
}

source "vultr" "s3-server" {
  api_key              = var.vultr_api_key
  os_id                = 1743
  plan_id              = "vc2-1c-2gb"
  region_id            = var.vultr_region
  ssh_username         = "root"
  state_timeout        = "25m"
  snapshot_description = "${var.snapshot_prefix}{{timestamp}}"
  instance_label       = "pinner-s3-vultr-builder"
  hostname             = "s3-server-build"
  tags                 = ["s3-server", "marketplace", "packer"]
}

build {
  sources = ["source.vultr.s3-server"]

  # Wait for cloud-init to finish before provisioning
  provisioner "shell" {
    inline = ["cloud-init status --wait"]
  }

  # System updates before installing anything
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "LC_ALL=C",
      "LANG=en_US.UTF-8",
      "LC_CTYPE=en_US.UTF-8",
    ]
    inline = [
      "apt-get -qqy update",
      "apt-get -qqy -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade",
      "apt-get -qqy clean",
    ]
  }

  # Upload docker-compose.yml for the shared provisioner
  provisioner "file" {
    source      = "${path.root}/../../docker-compose.yml"
    destination = "/tmp/docker-compose.yml"
  }

  # Upload MOTD (shared)
  provisioner "file" {
    source      = "${path.root}/../shared/files/etc/update-motd.d/99-one-click"
    destination = "/etc/update-motd.d/99-one-click"
  }

  # Run the shared provisioner (Docker install, compose, systemd, .env)
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "LC_ALL=C",
      "LANG=en_US.UTF-8",
      "LC_CTYPE=en_US.UTF-8",
    ]
    script = "${path.root}/../../packer/scripts/install-s3-server.sh"
  }

  # Upload cloud-init per-instance boot script (shared)
  provisioner "file" {
    source      = "${path.root}/../shared/files/var/lib/cloud/scripts/per-instance/001_onboot"
    destination = "/var/lib/cloud/scripts/per-instance/001_onboot"
  }

  # Configure firewall and force SSH logout, then make boot script executable
  # 014-ufw and 018-force-ssh-logout are shared
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "LC_ALL=C",
      "LANG=en_US.UTF-8",
      "LC_CTYPE=en_US.UTF-8",
    ]
    scripts = [
      "${path.root}/../shared/scripts/014-ufw-s3.sh",
      "${path.root}/../shared/scripts/018-force-ssh-logout.sh",
    ]
  }

  provisioner "shell" {
    inline = [
      "chmod +x /etc/update-motd.d/99-one-click",
      "chmod +x /var/lib/cloud/scripts/per-instance/001_onboot",
    ]
  }

  # Run cleanup script last (clears logs, SSH keys, bash history, zeros disk)
  provisioner "shell" {
    script = "scripts/900-cleanup.sh"
  }

  # Output manifest.json with snapshot ID for release automation
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
