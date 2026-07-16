packer {
  required_plugins {
    digitalocean = {
      source  = "github.com/digitalocean/digitalocean"
      version = ">= 1.3.0"
    }
  }
}

variable "do_api_token" {
  type      = string
  default   = "${env("DIGITALOCEAN_API_TOKEN")}"
  sensitive = true
}

variable "do_region" {
  type    = string
  default = "nyc3"
}

variable "do_ssh_key_id" {
  type      = string
  default   = "${env("DO_SSH_KEY_ID")}"
  sensitive = true
}

variable "do_ssh_private_key_file" {
  type    = string
  default = "${env("HOME")}/.ssh/id_ed25519"
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
  default = "pinner-s3-do-"
}

source "digitalocean" "s3-server" {
  api_token            = var.do_api_token
  image                = "ubuntu-22-04-x64"
  size                 = "s-1vcpu-1gb"
  region               = var.do_region
  ssh_username         = "root"
  droplet_name         = "pinner-s3-do-builder"
  snapshot_name        = "${var.snapshot_prefix}{{timestamp}}"
  ssh_key_id           = var.do_ssh_key_id
  ssh_private_key_file = var.do_ssh_private_key_file
}

build {
  sources = ["source.digitalocean.s3-server"]

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

  # Upload MOTD
  provisioner "file" {
    source      = "files/etc/update-motd.d/99-one-click"
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

  # Upload cloud-init per-instance boot script
  provisioner "file" {
    source      = "files/var/lib/cloud/scripts/per-instance/001_onboot"
    destination = "/var/lib/cloud/scripts/per-instance/001_onboot"
  }

  # Configure firewall, application tag, force SSH logout, and make boot script executable
  provisioner "shell" {
    environment_vars = [
      "application_name=${var.application_name}",
      "application_version=${var.application_version}",
      "DEBIAN_FRONTEND=noninteractive",
      "LC_ALL=C",
      "LANG=en_US.UTF-8",
      "LC_CTYPE=en_US.UTF-8",
    ]
    scripts = [
      "scripts/014-ufw-s3.sh",
      "scripts/020-application-tag.sh",
      "scripts/018-force-ssh-logout.sh",
    ]
  }

  provisioner "shell" {
    inline = [
      "chmod +x /etc/update-motd.d/99-one-click",
      "chmod +x /var/lib/cloud/scripts/per-instance/001_onboot",
    ]
  }

  # Run DO cleanup script last (clears logs, SSH keys, bash history, zeros disk, purges droplet-agent)
  provisioner "shell" {
    script = "scripts/900-cleanup.sh"
  }

  # Output manifest.json with snapshot ID for release automation
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
