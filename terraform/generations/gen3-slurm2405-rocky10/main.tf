# =============================================================================
# ROOT MODULE — BurstLab Gen 3
# Generation: gen3-slurm2405-rocky10
# OS: Rocky Linux 10
# Slurm: 24.05.x
# =============================================================================
# Same six modules as Gen 1 and Gen 2. Generation-specific differences:
#   - AMI: packer build ami/rocky10-slurm2405.pkr.hcl
#   - Config templates: configs/gen3-slurm2405-rocky10/
#   - slurm.conf: SlurmctldParameters=idle_on_node_suspend,cloud_reg_addrs
#     cloud_reg_addrs: burst nodes register with their actual EC2 IP — no
#     pre-configured NodeAddr required. Significant operational improvement.
#   - cgroup.conf: CgroupPlugin=cgroup/v2 (Rocky 10, cgroup v2 only)
#   - iptables: AMI installs iptables-nft (nftables backend compat layer)
#     so NAT init scripts work unchanged
#
# After `terraform apply`, SSH to the head node:
#   ssh -i ~/.ssh/<key>.pem rocky@$(terraform output -raw head_node_public_ip)
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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# =============================================================================
# RANDOM RESOURCES
# =============================================================================

resource "random_bytes" "munge_key" {
  length = 1024
}

resource "random_password" "slurmdbd_db" {
  length  = 24
  special = false
}

# =============================================================================
# MODULE: VPC
# =============================================================================
module "vpc" {
  source = "../../modules/vpc"

  cluster_name           = var.cluster_name
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
module "iam" {
  source = "../../modules/iam"

  cluster_name = var.cluster_name
}

# =============================================================================
# S3 BUCKET — cluster scripts
# =============================================================================
resource "aws_s3_bucket" "scripts" {
  bucket_prefix = "${var.cluster_name}-scripts-"
  force_destroy = true

  tags = {
    Name       = "${var.cluster_name}-scripts"
    Project    = "burstlab"
    Generation = "gen3"
    ManagedBy  = "terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "validate_script" {
  bucket  = aws_s3_bucket.scripts.id
  key     = "validate-cluster.sh"
  content = file("${local.scripts_dir}/validate-cluster.sh")
}

resource "aws_s3_object" "demo_script" {
  bucket  = aws_s3_bucket.scripts.id
  key     = "demo-burst.sh"
  content = file("${local.scripts_dir}/demo-burst.sh")
}

resource "aws_iam_role_policy" "head_node_scripts_s3" {
  name = "${var.cluster_name}-head-node-scripts-s3"
  role = module.iam.head_node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.scripts.arn}/*"
    }]
  })
}

# =============================================================================
# MODULE: SHARED STORAGE (EFS)
# =============================================================================
module "shared_storage" {
  source = "../../modules/shared-storage"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  efs_sg_id            = module.vpc.efs_sg_id
  management_subnet_id = module.vpc.management_subnet_id
  cloud_subnet_b_id    = module.vpc.cloud_subnet_b_id
}

# EFS DNS propagation wait (up to 90s after mount target becomes available)
resource "time_sleep" "efs_dns" {
  create_duration = "90s"
  depends_on      = [module.shared_storage]
}

# =============================================================================
# MODULE: HEAD NODE
# =============================================================================
module "head_node" {
  source = "../../modules/head-node"

  cluster_name          = var.cluster_name
  ami_id                = var.head_node_ami
  instance_type         = var.head_node_instance_type
  key_name              = var.key_name
  subnet_id             = module.vpc.management_subnet_id
  sg_id                 = module.vpc.head_node_sg_id
  instance_profile_name = module.iam.head_node_instance_profile_name
  static_private_ip     = local.head_node_private_ip

  onprem_route_table_id = module.vpc.onprem_route_table_id
  cloud_route_table_id  = module.vpc.cloud_route_table_id

  munge_key_b64        = random_bytes.munge_key.base64
  slurmdbd_db_password = random_password.slurmdbd_db.result
  efs_dns_name         = module.shared_storage.efs_dns_name

  onprem_cidr  = module.vpc.onprem_subnet_cidr
  cloud_cidr_a = module.vpc.cloud_subnet_a_cidr
  cloud_cidr_b = module.vpc.cloud_subnet_b_cidr

  slurm_conf         = local.slurm_conf
  slurmdbd_conf      = local.slurmdbd_conf
  cgroup_conf        = local.cgroup_conf
  plugin_config_json = local.plugin_config_json
  partitions_json    = local.partitions_json

  compute_node_count = var.compute_node_count
  aws_region         = var.aws_region

  scripts_bucket_name = aws_s3_bucket.scripts.id

  depends_on = [time_sleep.efs_dns]
}

# =============================================================================
# MODULE: BURST CONFIG (Launch Template)
# =============================================================================
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

  munge_key_b64        = random_bytes.munge_key.base64
  efs_dns_name         = module.shared_storage.efs_dns_name
  head_node_private_ip = local.head_node_private_ip
  aws_region           = var.aws_region
  generation           = "gen3"
}

# =============================================================================
# MODULE: COMPUTE NODES
# =============================================================================
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
  efs_dns_name  = module.shared_storage.efs_dns_name

  head_node_private_ip = local.head_node_private_ip
  onprem_cidr          = module.vpc.onprem_subnet_cidr

  depends_on = [time_sleep.efs_dns]
}
