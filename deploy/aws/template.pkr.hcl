packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.2.8"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_access_key" {
  type      = string
  default   = env("AWS_ACCESS_KEY_ID")
  sensitive = true
}

variable "aws_secret_key" {
  type      = string
  default   = env("AWS_SECRET_ACCESS_KEY")
  sensitive = true
}

variable "aws_session_token" {
  type      = string
  default   = env("AWS_SESSION_TOKEN")
  sensitive = true
}

variable "snapshot_prefix" {
  type    = string
  default = "pinner-s3-aws-"
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "subnet_id" {
  type    = string
  default = ""
}

variable "application_name" {
  type    = string
  default = "Pinner S3 Server"
}

variable "application_version" {
  type    = string
  default = "1.0.0"
}

source "amazon-ebs" "s3-server" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  token      = var.aws_session_token

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  instance_type   = "t3.small"
  ssh_username    = "ubuntu"
  ami_name        = "${var.snapshot_prefix}{{timestamp}}"
  ami_description = "Pinner S3 Server with Docker, docker-compose, and auto-update sidecar (x86-64)"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  vpc_id    = var.vpc_id != "" ? var.vpc_id : null
  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  tags = {
    Name         = "pinner-s3-server"
    Architecture = "x86-64"
    Project      = "pinner"
    Description  = "Pinner S3 Server Marketplace AMI (x86-64)"
  }

  snapshot_tags = {
    Name = "pinner-s3-aws-snapshot"
  }
}

build {
  sources = ["source.amazon-ebs.s3-server"]

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
      "sudo apt-get -qqy update",
      "sudo apt-get -qqy -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade",
      "sudo apt-get -qqy clean",
    ]
  }

  # Upload docker-compose.yml for the shared provisioner
  provisioner "file" {
    source      = "${path.root}/../../docker-compose.yml"
    destination = "/tmp/docker-compose.yml"
  }

  # Upload MOTD (shared) to /tmp first, then sudo mv to system path
  provisioner "file" {
    source      = "${path.root}/../shared/files/etc/update-motd.d/99-one-click"
    destination = "/tmp/99-one-click"
  }

  # Upload cloud-init per-instance boot script (shared) to /tmp first
  provisioner "file" {
    source      = "${path.root}/../shared/files/var/lib/cloud/scripts/per-instance/001_onboot"
    destination = "/tmp/001_onboot"
  }

  # Upload AWS-specific credential parser to /tmp first
  provisioner "file" {
    source      = "scripts/000-aws-credentials.sh"
    destination = "/tmp/000-aws-credentials.sh"
  }

  # Move files to system paths with sudo and set executable bits
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/update-motd.d /var/lib/cloud/scripts/per-instance",
      "sudo mv /tmp/99-one-click /etc/update-motd.d/99-one-click",
      "sudo mv /tmp/001_onboot /var/lib/cloud/scripts/per-instance/001_onboot",
      "sudo mv /tmp/000-aws-credentials.sh /var/lib/cloud/scripts/per-instance/000-aws-credentials.sh",
      "sudo chmod +x /etc/update-motd.d/99-one-click",
      "sudo chmod +x /var/lib/cloud/scripts/per-instance/001_onboot",
      "sudo chmod +x /var/lib/cloud/scripts/per-instance/000-aws-credentials.sh",
    ]
  }

  # Run the shared provisioner (Docker install, compose, systemd, .env)
  # Use sudo since AWS provisioner connects as 'ubuntu' user, not root
  provisioner "shell" {
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "LC_ALL=C",
      "LANG=en_US.UTF-8",
      "LC_CTYPE=en_US.UTF-8",
    ]
    script = "${path.root}/../../packer/scripts/install-s3-server.sh"
  }

  # Configure firewall and SSH lockout (shared)
  # Use sudo since AWS provisioner connects as 'ubuntu' user, not root
  provisioner "shell" {
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
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

  # AWS Marketplace hardening: disable password auth and lock root login
  provisioner "shell" {
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config",
      "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config",
      "systemctl restart sshd || true",
    ]
  }

  # Run cleanup script last
  provisioner "shell" {
    execute_command = "sudo bash -c '{{ .Vars }} {{ .Path }}'"
    script          = "scripts/900-cleanup.sh"
  }

  # Output manifest.json with AMI ID for release automation
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
