# =============================================================================
# VPC MODULE - BurstLab Gen 1
# =============================================================================
# Creates the full network topology for the "mock on-prem" HPC cluster.
#
# Topology:
#   VPC 10.0.0.0/16
#   ├── management  10.0.0.0/24  (us-west-2a) - head node, public EIP
#   ├── on-prem     10.0.1.0/24  (us-west-2a) - compute01-04, no public IPs
#   ├── cloud-a     10.0.2.0/24  (us-west-2a) - burst nodes
#   └── cloud-b     10.0.3.0/24  (us-west-2b) - burst nodes, second AZ
#
# The head node acts as a NAT router for the on-prem and cloud subnets.
# Routes for 0.0.0.0/0 pointing to the head node ENI are added by the
# head-node module AFTER the instance is created (chicken-and-egg avoided
# by keeping route resources in the head-node module).
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
# A dedicated VPC isolates BurstLab from other AWS resources and lets us
# define exactly what traffic is allowed. The /16 gives ample room for
# multiple subnet generations.
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # enable_dns_support + enable_dns_hostnames are both required for EFS
  # mount targets to be reachable by their DNS name (e.g.,
  # fs-XXXX.efs.us-west-2.amazonaws.com). Without them, DNS resolution
  # inside the VPC fails and EFS mounts hang.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name       = "${var.cluster_name}-vpc"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
# Required for the management subnet to reach the internet (SSH, yum updates,
# AWS API calls from the head node). The IGW is attached to the VPC; the
# management route table below points 0.0.0.0/0 here.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name       = "${var.cluster_name}-igw"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# =============================================================================
# SUBNETS
# =============================================================================

# -----------------------------------------------------------------------------
# Management subnet - head node lives here
# -----------------------------------------------------------------------------
# map_public_ip_on_launch = false because the head node gets a static EIP
# (allocated in the head-node module). Relying on auto-assigned IPs would
# break DNS-based access every time the instance is replaced.
resource "aws_subnet" "management" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.management_subnet_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = false

  tags = {
    Name       = "${var.cluster_name}-mgmt-subnet"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Role       = "management"
  }
}

# -----------------------------------------------------------------------------
# On-prem subnet - simulated private compute network
# -----------------------------------------------------------------------------
# No public IPs - mimics a real HPC environment where compute nodes live on
# an isolated private network. Internet access flows through the head node NAT.
resource "aws_subnet" "onprem" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.onprem_subnet_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = false

  tags = {
    Name       = "${var.cluster_name}-onprem-subnet"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Role       = "onprem-compute"
  }
}

# -----------------------------------------------------------------------------
# Cloud burst subnet A - us-west-2a
# -----------------------------------------------------------------------------
# Burst nodes launched by the aws-plugin-for-slurm land here (or in subnet B).
# Keeping burst nodes in the same VPC as the "on-prem" network means Slurm
# can reach them directly over private IPs - no VPN or Direct Connect needed.
resource "aws_subnet" "cloud_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.cloud_subnet_a_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = false

  tags = {
    Name       = "${var.cluster_name}-cloud-a-subnet"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Role       = "cloud-burst"
  }
}

# -----------------------------------------------------------------------------
# Cloud burst subnet B - us-west-2b
# -----------------------------------------------------------------------------
# A second AZ improves capacity availability. EC2 spot and on-demand pools are
# independent per AZ, so spanning two AZs roughly doubles the chance of getting
# burst capacity when demand is high.
resource "aws_subnet" "cloud_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.cloud_subnet_b_cidr
  availability_zone       = var.az_b
  map_public_ip_on_launch = false

  tags = {
    Name       = "${var.cluster_name}-cloud-b-subnet"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Role       = "cloud-burst"
  }
}

# =============================================================================
# ROUTE TABLES
# =============================================================================

# -----------------------------------------------------------------------------
# Management route table - default route via IGW
# -----------------------------------------------------------------------------
# The head node needs outbound internet access for: AWS API calls (EC2 Fleet),
# yum package repos, and any external services. The IGW provides this.
resource "aws_route_table" "management" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name       = "${var.cluster_name}-mgmt-rtb"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

resource "aws_route_table_association" "management" {
  subnet_id      = aws_subnet.management.id
  route_table_id = aws_route_table.management.id
}

# -----------------------------------------------------------------------------
# On-prem route table - default route added later by head-node module
# -----------------------------------------------------------------------------
# This table is created empty (no default route). The head-node module adds
# aws_route.onprem_nat pointing 0.0.0.0/0 → head node ENI. We split it this
# way because the ENI ID isn't known until the EC2 instance is created.
resource "aws_route_table" "onprem" {
  vpc_id = aws_vpc.main.id

  # Note: NO default route here. The head-node module adds it after EC2 launch.
  # This is intentional - the route must reference the head node's ENI ID.

  tags = {
    Name       = "${var.cluster_name}-onprem-rtb"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

resource "aws_route_table_association" "onprem" {
  subnet_id      = aws_subnet.onprem.id
  route_table_id = aws_route_table.onprem.id
}

# -----------------------------------------------------------------------------
# Cloud route table - shared by both burst subnets, default route added later
# -----------------------------------------------------------------------------
# Both cloud subnets share one route table. Burst nodes need outbound internet
# for yum, EFS mounts, and AWS API. Traffic goes through the head node NAT
# (same as on-prem compute) - this is by design to mirror real cloud-bursting
# architectures where burst nodes access the internet via the customer's gateway.
resource "aws_route_table" "cloud" {
  vpc_id = aws_vpc.main.id

  # Note: NO default route here. Added by head-node module post-launch.

  tags = {
    Name       = "${var.cluster_name}-cloud-rtb"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

resource "aws_route_table_association" "cloud_a" {
  subnet_id      = aws_subnet.cloud_a.id
  route_table_id = aws_route_table.cloud.id
}

resource "aws_route_table_association" "cloud_b" {
  subnet_id      = aws_subnet.cloud_b.id
  route_table_id = aws_route_table.cloud.id
}

# =============================================================================
# SECURITY GROUPS
# =============================================================================

# -----------------------------------------------------------------------------
# Head node security group
# -----------------------------------------------------------------------------
# Allows:
#   - SSH (22) from anywhere - for lab access. In production you'd restrict to
#     a bastion or VPN CIDR.
#   - All traffic from within the VPC - Slurm, Munge, NFS/EFS, slurmctld,
#     slurmdbd, srun, squeue, etc. all run over private IPs.
#   - All outbound - needed for AWS API (EC2 Fleet), yum, EFS.
resource "aws_security_group" "head_node" {
  name        = "${var.cluster_name}-head-node-sg"
  description = "Head node: SSH from internet + all VPC traffic for Slurm/Munge/EFS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from anywhere - lab access (restrict in production)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "All traffic from within VPC - Slurm (6817/6818/6819), Munge (no fixed port), EFS (2049), srun forwarding"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound - AWS API, yum repos, EFS, internet for updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "${var.cluster_name}-head-node-sg"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Compute node security group (on-prem simulated nodes)
# -----------------------------------------------------------------------------
# On-prem compute nodes only talk to things inside the VPC. All traffic within
# the VPC CIDR covers: Slurmd (6818), Munge auth, NFS/EFS (2049), and srun
# I/O forwarding. No inbound from internet - these nodes have no public IPs.
resource "aws_security_group" "compute_node" {
  name        = "${var.cluster_name}-compute-node-sg"
  description = "On-prem compute nodes: all VPC traffic only (no public ingress)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from VPC - Slurmd (6818), Munge, EFS, job I/O"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound - internet via head node NAT for yum/updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "${var.cluster_name}-compute-node-sg"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Burst node security group (cloud burst nodes)
# -----------------------------------------------------------------------------
# Same logic as compute nodes: burst nodes only need VPC-internal access.
# They communicate with slurmctld on the head node, mount EFS, and authenticate
# via Munge - all over private IPs. Internet access goes through head node NAT.
resource "aws_security_group" "burst_node" {
  name        = "${var.cluster_name}-burst-node-sg"
  description = "Cloud burst nodes: all VPC traffic only, internet via head-node NAT"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from VPC - Slurmd, Munge, EFS, srun I/O"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound - goes through head node NAT for external access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "${var.cluster_name}-burst-node-sg"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# EFS security group
# -----------------------------------------------------------------------------
# EFS mount targets accept NFS traffic (TCP 2049) from any host in the VPC.
# This covers the head node, on-prem compute nodes, and burst nodes - all of
# which need to mount /u and /opt/slurm from EFS.
resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "EFS mount targets: NFS (2049) from VPC CIDR only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "NFS from VPC - all nodes mount EFS for /u and /opt/slurm"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound (standard AWS SG requirement, EFS does not initiate connections)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "${var.cluster_name}-efs-sg"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}
