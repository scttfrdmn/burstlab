# =============================================================================
# ROOT MODULE — BurstLab Gen 1
# Generation: gen1-slurm2205-centos8
# =============================================================================
# This is the top-level Terraform configuration for BurstLab Gen 1.
# It wires together all modules to produce a complete "mock on-prem" HPC
# cluster that demonstrates Slurm cloud bursting to AWS EC2.
#
# Deployment order (managed automatically by Terraform dependency graph):
#   1. VPC + subnets + security groups
#   2. IAM roles and instance profiles
#   3. EFS filesystem + mount targets
#   4. Head node EC2 instance + EIP + NAT routes
#   5. Compute nodes (on-prem simulation)
#   6. Burst launch template
#
# After `terraform apply`, SSH to the head node:
#   ssh -i ~/.ssh/<key>.pem centos@$(terraform output -raw head_node_public_ip)
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # State is stored locally for BurstLab Gen 1.
  # WHY local state? This is a learning platform — local state keeps the setup
  # simple and avoids needing an S3 bucket or DynamoDB table. In production
  # you would use a remote backend (S3 + DynamoDB locking).
  # backend "local" {}  # Default — no explicit block needed.
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# =============================================================================
# RANDOM RESOURCES — generated secrets
# =============================================================================

# -----------------------------------------------------------------------------
# Munge key
# -----------------------------------------------------------------------------
# Munge is the authentication layer for all Slurm communications. Every node
# in the cluster (head, compute, burst) must share EXACTLY this key.
# A 1024-byte random key provides strong security.
#
# random_bytes gives us a .base64 attribute directly — no need for base64encode().
# We pass this to every node's UserData so they all write the identical key to
# /etc/munge/munge.key.
resource "random_bytes" "munge_key" {
  length = 1024
}

# -----------------------------------------------------------------------------
# slurmdbd database password
# -----------------------------------------------------------------------------
# slurmdbd stores job accounting data in a local MariaDB database.
# This password is generated once and injected into slurmdbd.conf via UserData.
# special = false avoids shell quoting issues when the password is embedded
# in shell scripts inside UserData.
resource "random_password" "slurmdbd_db" {
  length  = 24
  special = false
}

# =============================================================================
# MODULE: VPC
# =============================================================================
# Creates the network topology: VPC, 4 subnets, IGW, route tables, and
# security groups. Everything else depends on this module.
module "vpc" {
  source = "../../modules/vpc"

  cluster_name = var.cluster_name

  # CIDR blocks follow the architecture spec:
  #   10.0.0.0/16  — VPC
  #   10.0.0.0/24  — management (head node)
  #   10.0.1.0/24  — on-prem compute
  #   10.0.2.0/24  — cloud burst AZ-A
  #   10.0.3.0/24  — cloud burst AZ-B
  vpc_cidr               = "10.0.0.0/16"
  management_subnet_cidr = "10.0.0.0/24"
  onprem_subnet_cidr     = "10.0.1.0/24"
  cloud_subnet_a_cidr    = "10.0.2.0/24"
  cloud_subnet_b_cidr    = "10.0.3.0/24"
  az_a                   = "us-west-2a"
  az_b                   = "us-west-2b"
}

# =============================================================================
# MODULE: IAM
# =============================================================================
# Creates IAM roles for head node (EC2 Fleet + PassRole) and burst nodes
# (DescribeTags). Both roles get AmazonSSMManagedInstanceCore for SSM access.
module "iam" {
  source = "../../modules/iam"

  cluster_name = var.cluster_name
  # Both IAM roles (head node and burst node) are created in the same module.
  # The head node PassRole policy references the burst node role ARN directly
  # via aws_iam_role.burst_node.arn within the module — no cross-module cycle.
}

# =============================================================================
# MODULE: SHARED STORAGE (EFS)
# =============================================================================
# Creates the EFS filesystem with mount targets in all 4 subnets and access
# points for /home and /opt/slurm.
module "shared_storage" {
  source = "../../modules/shared-storage"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  efs_sg_id            = module.vpc.efs_sg_id
  management_subnet_id = module.vpc.management_subnet_id
  onprem_subnet_id     = module.vpc.onprem_subnet_id
  cloud_subnet_a_id    = module.vpc.cloud_subnet_a_id
  cloud_subnet_b_id    = module.vpc.cloud_subnet_b_id
}

# =============================================================================
# MODULE: HEAD NODE
# =============================================================================
# Creates the head node EC2 instance, EIP, and NAT routes.
# This module ALSO adds the default routes to the on-prem and cloud route
# tables (the ones created empty in the VPC module).
module "head_node" {
  source = "../../modules/head-node"

  cluster_name         = var.cluster_name
  ami_id               = var.head_node_ami
  instance_type        = var.head_node_instance_type
  key_name             = var.key_name
  subnet_id            = module.vpc.management_subnet_id
  sg_id                = module.vpc.head_node_sg_id
  instance_profile_arn = module.iam.head_node_instance_profile_arn

  # Static private IP — must match local.head_node_private_ip (var.head_node_static_ip).
  # This value is used in slurm.conf and the burst/compute node UserData, both of
  # which are rendered before the EC2 instance is created. The static IP ensures
  # those configs are correct without a circular Terraform dependency.
  static_private_ip = local.head_node_private_ip

  # Route table IDs for NAT routes — the head node module adds 0.0.0.0/0 → ENI
  onprem_route_table_id = module.vpc.onprem_route_table_id
  cloud_route_table_id  = module.vpc.cloud_route_table_id

  # Munge key — shared secret for Slurm authentication
  munge_key_b64 = random_bytes.munge_key.base64

  # slurmdbd password — injected into slurmdbd.conf
  slurmdbd_db_password = random_password.slurmdbd_db.result

  # EFS — head node mounts these to /home and /opt/slurm
  efs_dns_name              = module.shared_storage.efs_dns_name
  efs_home_access_point_id  = module.shared_storage.efs_home_access_point_id
  efs_slurm_access_point_id = module.shared_storage.efs_slurm_access_point_id

  # Network info for iptables NAT configuration
  onprem_cidr  = module.vpc.onprem_subnet_cidr
  cloud_cidr_a = module.vpc.cloud_subnet_a_cidr
  cloud_cidr_b = module.vpc.cloud_subnet_b_cidr

  # Rendered Slurm config files (from locals.tf)
  slurm_conf         = local.slurm_conf
  slurmdbd_conf      = local.slurmdbd_conf
  cgroup_conf        = local.cgroup_conf
  plugin_config_json = local.plugin_config_json
  partitions_json    = local.partitions_json

  compute_node_count = var.compute_node_count
  aws_region         = var.aws_region
}

# =============================================================================
# MODULE: BURST CONFIG (Launch Template)
# =============================================================================
# Creates the EC2 launch template for burst nodes.
# Must be created BEFORE compute nodes because locals.tf references
# module.burst_config.launch_template_id when rendering plugin_config.json
# and partitions.json — and those rendered configs are passed to the head node.
#
# NOTE: This module is declared before head_node in this file, but Terraform
# resolves the actual order from the dependency graph, not file order.
# The actual dependency chain is:
#   burst_config → (no module deps, uses vpc + iam outputs)
#   head_node → burst_config (via locals.tf referencing launch_template_id)
module "burst_config" {
  source = "../../modules/burst-config"

  cluster_name                     = var.cluster_name
  ami_id                           = local.effective_compute_ami
  burst_node_instance_type         = var.burst_node_instance_type
  burst_node_instance_profile_name = module.iam.burst_node_instance_profile_name
  burst_node_sg_id                 = module.vpc.burst_node_sg_id
  cloud_subnet_a_id                = module.vpc.cloud_subnet_a_id
  cloud_subnet_b_id                = module.vpc.cloud_subnet_b_id
  key_name                         = var.key_name

  # Munge key — burst nodes MUST use the same key as head + compute nodes
  munge_key_b64 = random_bytes.munge_key.base64

  # EFS
  efs_dns_name              = module.shared_storage.efs_dns_name
  efs_home_access_point_id  = module.shared_storage.efs_home_access_point_id
  efs_slurm_access_point_id = module.shared_storage.efs_slurm_access_point_id

  # Head node IP — burst nodes add this to /etc/hosts so they can reach slurmctld.
  # Uses local.head_node_private_ip (static 10.0.0.10) so the launch template
  # can be created before the head node EC2 instance exists — no circular dep.
  head_node_private_ip = local.head_node_private_ip

  aws_region = var.aws_region
}

# =============================================================================
# MODULE: COMPUTE NODES
# =============================================================================
# Creates the always-on "on-prem" compute nodes (compute01-04).
# These depend on the head node being created first so we can pass
# head_node_private_ip for /etc/hosts configuration.
module "compute_nodes" {
  source = "../../modules/compute-nodes"

  cluster_name       = var.cluster_name
  ami_id             = local.effective_compute_ami
  instance_type      = var.compute_node_instance_type
  key_name           = var.key_name
  subnet_id          = module.vpc.onprem_subnet_id
  sg_id              = module.vpc.compute_node_sg_id
  compute_node_count = var.compute_node_count

  munge_key_b64 = random_bytes.munge_key.base64

  efs_dns_name              = module.shared_storage.efs_dns_name
  efs_home_access_point_id  = module.shared_storage.efs_home_access_point_id
  efs_slurm_access_point_id = module.shared_storage.efs_slurm_access_point_id

  # Uses local.head_node_private_ip (static 10.0.0.10) — same reason as burst_config.
  # Compute nodes are launched concurrently with the head node, so we can't
  # wait for head_node.private_ip to be known.
  head_node_private_ip = local.head_node_private_ip

  # onprem_cidr is used by the compute node init script to build /etc/hosts
  # entries for all nodes (using cidrhost()) so they resolve each other.
  onprem_cidr = module.vpc.onprem_subnet_cidr
}
