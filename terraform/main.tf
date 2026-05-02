###############################################################################
# AWS Kubernetes Cluster - Infrastructure
#
# Provisions the AWS resources from docs/student-aws-cluster-setup-guide.md:
#   - EC2 key pair (private key written to ./k8s-cluster-key.pem)
#   - Elastic IP (associated to the control plane)
#   - Security group with SSH (22), Kubernetes API (6443), and intra-cluster rules
#   - IAM policy + role + instance profile for the AWS EBS CSI Driver
#   - 4x t3.medium Ubuntu 24.04 instances (1 control plane + 3 workers)
#     with Step 3 node prep baked into user_data
#
# After `terraform apply`, follow Steps 4-9 of the guide (kubeadm init, join,
# Calico, EBS CSI driver) via SSH using the outputs printed below.
#
# Usage:
#   cd terraform
#   terraform init
#   terraform apply -var="my_ip_cidr=$(curl -s ifconfig.me)/32"
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# Variables
###############################################################################

variable "aws_region" {
  description = "AWS region. Pluralsight cloud sandbox restricts actions to us-east-1 or us-west-2."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.aws_region)
    error_message = "Pluralsight AWS sandbox only allows us-east-1 or us-west-2."
  }
}

variable "my_ip_cidr" {
  description = "Your public IP for SSH and Kubernetes API access. Accepts either a bare IPv4 (1.2.3.4, treated as /32) or full CIDR (1.2.3.4/32). Get it with: curl ifconfig.me"
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$", var.my_ip_cidr))
    error_message = "my_ip_cidr must be an IPv4 address (1.2.3.4) or CIDR block (1.2.3.4/32)."
  }
}

locals {
  my_ip_cidr = strcontains(var.my_ip_cidr, "/") ? var.my_ip_cidr : "${var.my_ip_cidr}/32"
}

variable "key_name" {
  description = "Name for the EC2 key pair. The private key is written to ./<key_name>.pem."
  type        = string
  default     = "k8s-cluster-key"
}

variable "instance_type" {
  description = "EC2 instance type for all nodes. t3.small (2 vCPU / 2 GiB) is the smallest size that satisfies kubeadm preflight; t3.medium gives more headroom if available."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size_gb" {
  description = "Size of the root EBS volume in GiB."
  type        = number
  default     = 20
}

variable "worker_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 3
}

###############################################################################
# Lookups: default VPC + subnet, latest Ubuntu 24.04 AMI
###############################################################################

data "aws_vpc" "default" {
  default = true
}

data "aws_ec2_instance_type_offerings" "by_az" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  location_type = "availability-zone"
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.by_az.locations
  }
}

data "aws_ami" "ubuntu_2404" {
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

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

###############################################################################
# SSH key pair (Step 1.1)
###############################################################################

resource "tls_private_key" "k8s" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "k8s" {
  key_name   = var.key_name
  public_key = tls_private_key.k8s.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.k8s.private_key_pem
  filename        = "${path.module}/${var.key_name}.pem"
  file_permission = "0400"
}

###############################################################################
# Elastic IP (Step 1.2)
###############################################################################

resource "aws_eip" "control_plane" {
  domain = "vpc"
  tags = {
    Name = "k8s-cluster-eip"
  }
}

###############################################################################
# Security group (Step 1.3)
###############################################################################

resource "aws_security_group" "k8s" {
  name        = "k8s-cluster-sg"
  description = "Kubernetes cluster security group"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "k8s-cluster-sg"
  }
}

resource "aws_security_group_rule" "ssh_from_my_ip" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [local.my_ip_cidr]
  security_group_id = aws_security_group.k8s.id
  description       = "SSH access"
}

resource "aws_security_group_rule" "kube_api_from_my_ip" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = [local.my_ip_cidr]
  security_group_id = aws_security_group.k8s.id
  description       = "Kubernetes API (external)"
}

resource "aws_security_group_rule" "intra_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.k8s.id
  security_group_id        = aws_security_group.k8s.id
  description              = "Internal cluster communication"
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s.id
  description       = "Allow all outbound"
}

###############################################################################
# IAM for EBS CSI Driver (Step 1.4)
###############################################################################

resource "aws_iam_policy" "ebs_csi_driver" {
  name        = "EBS-CSI-Driver-Policy"
  description = "Permissions required by the AWS EBS CSI Driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyVolume",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = ["CreateVolume", "CreateSnapshot"]
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["ec2:DeleteTags"]
        Resource = [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume"]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume"]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DeleteVolume"]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DeleteVolume"]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DeleteVolume"]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/kubernetes.io/created-for/pvc/name" = "*"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DeleteSnapshot"]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeSnapshotName" = "*"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DeleteSnapshot"]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "k8s_node" {
  name = "K8sNodeRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "k8s_node_ebs_csi" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = aws_iam_policy.ebs_csi_driver.arn
}

resource "aws_iam_instance_profile" "k8s_node" {
  name = "K8sNodeRole"
  role = aws_iam_role.k8s_node.name
}

###############################################################################
# Per-node bootstrap (Step 3 of the guide)
###############################################################################

locals {
  node_user_data = <<EOT
#!/bin/bash
set -euxo pipefail

# Wait for any in-progress apt/dpkg operations to finish (cloud-init, unattended-upgrades).
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done

# --- Disable swap ---
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# --- Kernel modules ---
cat >/etc/modules-load.d/k8s.conf <<'MODS'
overlay
br_netfilter
MODS
modprobe overlay
modprobe br_netfilter

# --- Sysctl ---
cat >/etc/sysctl.d/k8s.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

# --- containerd ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# --- Kubernetes apt repo + packages (pinned to 1.33.6-1.1) ---
apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet=1.33.6-1.1 kubeadm=1.33.6-1.1 kubectl=1.33.6-1.1
apt-mark hold kubelet kubeadm kubectl
EOT
}

###############################################################################
# Control plane EC2 instance (Step 2)
###############################################################################

resource "aws_instance" "control_plane" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  iam_instance_profile        = aws_iam_instance_profile.k8s_node.name
  associate_public_ip_address = true
  user_data                   = local.node_user_data

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
  }

  tags = {
    Name = "k8s-control-plane"
    Role = "control-plane"
  }
}

resource "aws_eip_association" "control_plane" {
  instance_id   = aws_instance.control_plane.id
  allocation_id = aws_eip.control_plane.id
}

###############################################################################
# Worker EC2 instances (Step 2)
###############################################################################

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  iam_instance_profile        = aws_iam_instance_profile.k8s_node.name
  associate_public_ip_address = true
  user_data                   = local.node_user_data

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
  }

  tags = {
    Name = "k8s-worker-${count.index + 1}"
    Role = "worker"
  }
}

###############################################################################
# Ansible jump box (runs the playbook against the cluster from inside the VPC)
###############################################################################

locals {
  jump_box_user_data = <<EOT
#!/bin/bash
set -euxo pipefail
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
while fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ansible jq
EOT
}

resource "aws_instance" "jump_box" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  associate_public_ip_address = true
  user_data                   = local.jump_box_user_data

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    delete_on_termination = true
  }

  tags = {
    Name = "k8s-ansible-jump"
    Role = "ansible-controller"
  }
}

###############################################################################
# Ansible inventory (written to ../ansible/inventory.yml)
# Uses private IPs because the jump box is inside the VPC.
###############################################################################

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.yml"
  file_permission = "0644"
  content = yamlencode({
    all = {
      vars = {
        elastic_ip               = aws_eip.control_plane.public_ip
        control_plane_private_ip = aws_instance.control_plane.private_ip
      }
      children = {
        control_plane = {
          hosts = {
            "k8s-control-plane" = {
              ansible_host = aws_instance.control_plane.private_ip
            }
          }
        }
        workers = {
          hosts = {
            for i, w in aws_instance.worker :
            "k8s-worker-${i + 1}" => { ansible_host = w.private_ip }
          }
        }
      }
    }
  })
}

###############################################################################
# Outputs
###############################################################################

output "elastic_ip" {
  description = "Elastic IP attached to the control plane (use for SSH and external kubectl)."
  value       = aws_eip.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Control plane private IP. Add to /etc/hosts on workers as 'k8s-api.local'."
  value       = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of worker nodes (for SSH)."
  value       = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes."
  value       = aws_instance.worker[*].private_ip
}

output "private_key_path" {
  description = "Path to the generated SSH private key (chmod 0400)."
  value       = local_sensitive_file.private_key.filename
}

output "ssh_control_plane" {
  description = "Ready-to-run SSH command for the control plane."
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.control_plane.public_ip}"
}

output "jump_box_public_ip" {
  description = "Public IP of the Ansible jump box (SSH from your laptop)."
  value       = aws_instance.jump_box.public_ip
}

output "ssh_jump_box" {
  description = "Ready-to-run SSH command for the jump box."
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.jump_box.public_ip}"
}
