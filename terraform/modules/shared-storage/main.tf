# =============================================================================
# SHARED STORAGE MODULE — BurstLab Gen 1
# =============================================================================
# Creates an EFS filesystem with mount targets in all four subnets.
#
# Why EFS?
#   Slurm requires that /opt/slurm (binaries, config, plugins) is identical
#   on every node — head node, compute nodes, AND burst nodes. In a real
#   on-prem cluster this is typically an NFS server. EFS gives us managed NFS
#   that scales automatically and survives node reboots/replacements.
#
# Two logical exports (enforced by access points):
#   /      → mounted as /home on all nodes     (user home directories)
#   /slurm → mounted as /opt/slurm on all nodes (Slurm install + config)
#
# Mount targets in all 4 subnets ensure:
#   - No cross-AZ NFS traffic (burst nodes in us-west-2b use the cloud-b target)
#   - All nodes can mount immediately without routing through another AZ
# =============================================================================

# -----------------------------------------------------------------------------
# EFS Filesystem
# -----------------------------------------------------------------------------
# performance_mode = "generalPurpose" — appropriate for HPC config files and
# home dirs. "maxIO" is for massively parallel I/O workloads (>100 clients
# doing heavy concurrent writes), which BurstLab doesn't need.
#
# throughput_mode = "bursting" — EFS credits scale with filesystem size.
# For a lab with small /opt/slurm and /home, bursting is cost-effective.
# Switch to "provisioned" if you observe throughput throttling.
#
# encrypted = true — encrypts data at rest using the default EFS KMS key.
# Good practice even for a lab; also required by some AWS security baselines.
resource "aws_efs_file_system" "main" {
  creation_token   = "${var.cluster_name}-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  lifecycle_policy {
    # Move files not accessed in 30 days to Infrequent Access storage class.
    # Saves cost for old log files and rarely-used home directory content.
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name       = "${var.cluster_name}-efs"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# =============================================================================
# EFS MOUNT TARGETS
# =============================================================================
# A mount target is the NFS endpoint for a subnet. Each mount target gets an
# IP address in the subnet's CIDR range and listens on TCP 2049.
# Instances connect to the mount target's DNS name, which resolves to the
# correct mount target IP for the instance's AZ.

# us-west-2a — covers management, onprem, and cloud-a subnets.
# EFS allows only one mount target per AZ. All three subnets in us-west-2a
# (management 10.0.0.0/24, onprem 10.0.1.0/24, cloud-a 10.0.2.0/24) reach
# EFS via this single mount target; VPC routing handles intra-AZ delivery.
resource "aws_efs_mount_target" "management" {
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.management_subnet_id
  security_groups = [var.efs_sg_id]
}

# us-west-2b — burst nodes launched in cloud-b subnet use this mount target.
resource "aws_efs_mount_target" "cloud_b" {
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.cloud_subnet_b_id
  security_groups = [var.efs_sg_id]
}

# =============================================================================
# EFS ACCESS POINTS
# =============================================================================
# Access points enforce a specific root directory and POSIX identity for mounts.
# This lets us share one EFS filesystem for both /home and /opt/slurm while
# keeping them isolated at the NFS level.

# -----------------------------------------------------------------------------
# /home access point
# -----------------------------------------------------------------------------
# root_directory path = "/" means the access point's root IS the EFS root.
# POSIX UID/GID 0 (root) with permissions 755 — the OS manages per-user dirs
# under /home normally once mounted.
resource "aws_efs_access_point" "home" {
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/home"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "755"
    }
  }

  tags = {
    Name       = "${var.cluster_name}-efs-home"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Export     = "/home"
  }
}

# -----------------------------------------------------------------------------
# /slurm access point → mounted at /opt/slurm
# -----------------------------------------------------------------------------
# Slurm is installed to /opt/slurm on all nodes. The entire /opt/slurm tree
# lives on EFS so that:
#   1. Config files (slurm.conf, partitions.json, etc.) are identical everywhere.
#   2. Burst nodes get Slurm binaries + config automatically on mount — no
#      separate config management step needed.
# UID/GID 0, permissions 755 — the slurm user (created during OS setup) manages
# /opt/slurm/etc contents at the application level.
resource "aws_efs_access_point" "slurm" {
  file_system_id = aws_efs_file_system.main.id

  root_directory {
    path = "/slurm"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "755"
    }
  }

  tags = {
    Name       = "${var.cluster_name}-efs-slurm"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Export     = "/opt/slurm"
  }
}
