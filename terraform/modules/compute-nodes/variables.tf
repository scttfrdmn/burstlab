variable "cluster_name" {
  description = "Cluster name prefix for resource naming."
  type        = string
}

variable "ami_id" {
  description = "AMI ID for compute nodes. Should use the same BurstLab Packer AMI as the head node to ensure identical Slurm version and configuration layout."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for on-prem compute nodes. m7a.2xlarge (8 vCPU / 32 GB) matches the head and burst nodes for consistency."
  type        = string
  default     = "m7a.2xlarge"
}

variable "key_name" {
  description = "EC2 key pair name. Allows SSH from the head node to compute nodes for Slurm job management (srun, sbatch step launch)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for compute nodes (on-prem subnet). All compute nodes share one subnet to simplify routing and security group rules."
  type        = string
}

variable "sg_id" {
  description = "Security group ID for compute nodes. Should allow all intra-VPC traffic (Slurmd 6818, Munge, EFS 2049)."
  type        = string
}

variable "munge_key_b64" {
  description = "Base64-encoded Munge key. Must be IDENTICAL to the key on the head node. Munge uses a shared secret — if the key differs, all Slurm RPCs will fail authentication."
  type        = string
  sensitive   = true
}

variable "efs_dns_name" {
  description = "EFS DNS name for mounting /u and /opt/slurm. Compute nodes get identical Slurm binaries and config by mounting the same EFS as the head node."
  type        = string
}


variable "compute_node_count" {
  description = "Number of on-prem compute nodes to create (compute01..N). These are always-on nodes that simulate a real on-prem HPC cluster. Default 4 matches a typical small demo cluster."
  type        = number
  default     = 4
}

variable "head_node_private_ip" {
  description = "Private IP of the head node. Written to /etc/hosts on each compute node so that hostname 'headnode' resolves to slurmctld. Passed to the template as head_node_ip."
  type        = string
}

variable "onprem_cidr" {
  description = "CIDR block of the on-prem compute subnet (e.g. 10.0.1.0/24). Used in the compute node init script to populate /etc/hosts entries for all compute nodes using cidrhost() so they can resolve each other by short name."
  type        = string
}
