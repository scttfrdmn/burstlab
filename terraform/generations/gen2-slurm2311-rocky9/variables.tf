# =============================================================================
# ROOT MODULE VARIABLES — BurstLab Gen 2
# Rocky Linux 9 + Slurm 23.11.x
# =============================================================================

variable "aws_region" {
  description = "AWS region where the cluster is deployed."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI named profile to use for authentication."
  type        = string
  default     = "aws"
}

variable "cluster_name" {
  description = "Name prefix applied to every resource. Use 'burstlab-gen2' to distinguish from Gen 1 and Gen 3 deployments in the same account."
  type        = string
  default     = "burstlab-gen2"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair in the target region. Used for SSH access to the head node."
  type        = string
  # No default — must provide your own.
}

variable "head_node_ami" {
  description = "AMI ID for the head node. Must be the output of: packer build ami/rocky9-slurm2311.pkr.hcl. AMI ID changes on each Packer build — get the latest with: aws ec2 describe-images --owners self --filters 'Name=name,Values=burstlab-gen2-*'"
  type        = string
  # No default — AMI is region-specific and built by Packer.
}

variable "compute_node_ami" {
  description = "AMI ID for compute and burst nodes. Defaults to head_node_ami (all nodes use the same AMI for consistency)."
  type        = string
  default     = ""
}

variable "head_node_instance_type" {
  description = "EC2 instance type for the head node. m7a.2xlarge (8 vCPU / 32 GB) is comfortable for a demo cluster."
  type        = string
  default     = "m7a.2xlarge"
}

variable "compute_node_instance_type" {
  description = "EC2 instance type for on-prem compute nodes."
  type        = string
  default     = "m7a.2xlarge"
}

variable "compute_node_count" {
  description = "Number of always-on 'on-prem' compute nodes."
  type        = number
  default     = 4
}

variable "burst_node_instance_type" {
  description = "EC2 instance type for cloud burst nodes."
  type        = string
  default     = "m7a.2xlarge"
}

variable "max_burst_nodes" {
  description = "Maximum number of simultaneous cloud burst nodes. Prevents runaway costs."
  type        = number
  default     = 10
}

variable "head_node_static_ip" {
  description = "Static private IP for the head node in the management subnet (10.0.0.0/24). Embedded in slurm.conf and burst/compute node /etc/hosts. Must be known before the EC2 instance is created (breaks Terraform circular dependency)."
  type        = string
  default     = "10.0.0.10"
}
