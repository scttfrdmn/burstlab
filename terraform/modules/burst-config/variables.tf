variable "cluster_name" {
  description = "Cluster name prefix for resource naming."
  type        = string
}

variable "ami_id" {
  description = "AMI ID for burst nodes. Must be the same BurstLab Packer AMI used for compute nodes — burst nodes need identical Slurm binaries so they can run the same jobs."
  type        = string
}

variable "burst_node_instance_type" {
  description = "EC2 instance type for burst nodes. m7a.2xlarge (8 vCPU / 32 GB) matches the compute nodes so job resource requests work identically on both partitions."
  type        = string
  default     = "m7a.2xlarge"
}

variable "burst_node_instance_profile_name" {
  description = "Name of the burst node IAM instance profile. Attached to the launch template so burst nodes start with the role that allows DescribeTags (needed to read the Slurm node name)."
  type        = string
}

variable "burst_node_sg_id" {
  description = "Security group ID for burst nodes. Applied to all burst nodes launched via this template."
  type        = string
}

variable "cloud_subnet_a_id" {
  description = "Subnet ID for cloud burst subnet A (us-west-2a). Listed in partitions.json so the plugin can launch burst nodes here."
  type        = string
}

variable "cloud_subnet_b_id" {
  description = "Subnet ID for cloud burst subnet B (us-west-2b). Second AZ for higher burst capacity availability."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name. Allows SSH from head node to burst nodes for debugging launched jobs."
  type        = string
}

variable "munge_key_b64" {
  description = "Base64-encoded Munge key. CRITICAL: burst nodes must use the exact same Munge key as the head node and compute nodes. If the key differs, slurmd on the burst node cannot authenticate with slurmctld and the node will never go IDLE."
  type        = string
  sensitive   = true
}

variable "efs_dns_name" {
  description = "EFS DNS name. Burst nodes mount /u and /opt/slurm from EFS just like compute nodes — this is what makes them 'configuration-free': everything they need is on the shared filesystem."
  type        = string
}


variable "head_node_private_ip" {
  description = "Private IP of the head node. Written to /etc/hosts on burst nodes so slurmd can reach slurmctld by hostname."
  type        = string
}

variable "aws_region" {
  description = "AWS region. Written into the burst node init script for any region-specific AWS CLI calls."
  type        = string
  default     = "us-west-2"
}

variable "generation" {
  description = "BurstLab generation label (gen1, gen2, gen3). Applied to EC2 resource tags so burst nodes from different generations can be identified and cleaned up independently."
  type        = string
  default     = "gen1"
}
