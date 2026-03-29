# =============================================================================
# ROOT MODULE VARIABLES — BurstLab Gen 1
# =============================================================================
# These are the only values you need to provide (or override) to deploy a
# complete BurstLab Gen 1 cluster. See terraform.tfvars.example for a template.

variable "aws_region" {
  description = "AWS region where the cluster is deployed. All resources (VPC, EC2, EFS) are created in this region. BurstLab is developed and tested in us-west-2."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI named profile to use for authentication. Must be configured in ~/.aws/credentials or ~/.aws/config. The 'aws' profile is used by convention for BurstLab development."
  type        = string
  default     = "aws"
}

variable "cluster_name" {
  description = "Name prefix applied to every resource (EC2 instances, VPC, IAM roles, EFS, etc.). Changing this lets you deploy multiple independent BurstLab environments in the same AWS account. Must be alphanumeric with hyphens only — it appears in IAM role names and EC2 hostnames."
  type        = string
  default     = "burstlab-gen1"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair in the target region. Used for SSH access to the head node (and optionally to compute/burst nodes). Create one in the AWS console or with: aws ec2 create-key-pair --key-name burstlab"
  type        = string
  # No default — you MUST provide your own key pair name.
}

variable "head_node_ami" {
  description = "AMI ID for the head node. Must be the output of: packer build ami/rocky8-slurm2205.pkr.hcl. This AMI has Rocky Linux 8, Slurm 22.05.11, MariaDB, and all dependencies pre-installed. The AMI ID changes every time you run Packer — get the latest from Packer output or: aws ec2 describe-images --owners self --filters Name=name,Values='burstlab-*'"
  type        = string
  # No default — AMI is region-specific and built by Packer.
}

variable "compute_node_ami" {
  description = "AMI ID for compute and burst nodes. Defaults to the same AMI as the head node — keeping all nodes on the same AMI ensures identical Slurm version and library paths, which prevents subtle runtime failures. Only override if you have a separate compute node AMI."
  type        = string
  default     = ""
  # Empty string means: use head_node_ami. See locals.tf for the conditional.
}

variable "head_node_instance_type" {
  description = "EC2 instance type for the head node. m7a.large (2 vCPU / 8 GB) runs slurmctld + slurmdbd + aws-plugin-for-slurm comfortably for a small demo cluster."
  type        = string
  default     = "m7a.large"
}

variable "compute_node_instance_type" {
  description = "EC2 instance type for on-prem compute nodes. m7a.large matches the head node for simplicity. In a real cluster these would typically be larger or specialized (HPC, GPU) instances."
  type        = string
  default     = "m7a.large"
}

variable "compute_node_count" {
  description = "Number of always-on 'on-prem' compute nodes. Default 4 simulates a small fixed HPC cluster. When all 4 nodes are busy, jobs overflow to cloud burst nodes."
  type        = number
  default     = 4
}

variable "burst_node_instance_type" {
  description = "EC2 instance type for cloud burst nodes. m7a.xlarge (4 vCPU / 16 GB) is intentionally larger than the on-prem compute nodes to demonstrate that burst nodes can have a different — often better — spec than on-prem hardware."
  type        = string
  default     = "m7a.xlarge"
}

variable "max_burst_nodes" {
  description = "Maximum number of cloud burst nodes that can be running simultaneously. Written into partitions.json (MaxNodes). Prevents runaway costs if a burst job spawns more nodes than expected."
  type        = number
  default     = 10
}

variable "head_node_static_ip" {
  description = "Static private IP for the head node within the management subnet (10.0.0.0/24). Default 10.0.0.10. This IP is embedded in slurm.conf (SlurmctldHost) and in the burst/compute node /etc/hosts entries. Changing this after initial deployment requires reprovisioning all nodes. The static IP is necessary to break a Terraform circular dependency: config files reference the head node IP, but config files are inputs to the head node resource."
  type        = string
  default     = "10.0.0.10"
}
