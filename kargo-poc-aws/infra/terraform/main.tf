# Une VM Ubuntu 24.04 dans le VPC par défaut, k3s installé au démarrage (user-data).
# Ports ouverts : 22 depuis allowed_ssh_cidr, 80/443 depuis allowed_http_cidr
# (par défaut la même IP). Les UI (Kargo, Argo CD, Argo Workflows, Excalidraw)
# sont exposées par la Gateway API (Traefik de k3s) sur *.apps.<IP>.sslip.io.

locals {
  allowed_http_cidr = coalesce(var.allowed_http_cidr, var.allowed_ssh_cidr)
}

data "aws_vpc" "default" {
  default = true
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "poc" {
  key_name_prefix = "kargo-poc-"
  public_key      = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_security_group" "poc" {
  name_prefix = "kargo-poc-"
  description = "POC Kargo: SSH + HTTP(S) depuis les IP autorisees"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP (Gateway API)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.allowed_http_cidr]
  }

  ingress {
    description = "HTTPS (Gateway API)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.allowed_http_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "poc" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.poc.key_name
  vpc_security_group_ids = [aws_security_group.poc.id]

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    k3s_channel = var.k3s_channel
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2
    http_endpoint = "enabled"
  }

  tags = {
    Name = "kargo-poc-excalidraw"
  }
}
