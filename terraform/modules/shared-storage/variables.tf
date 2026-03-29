variable "cluster_name" {
  description = "Name prefix for EFS resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where EFS mount targets will be created. EFS mount targets must be in the same VPC as the instances that mount them."
  type        = string
}

variable "efs_sg_id" {
  description = "Security group ID for EFS mount targets. Should allow NFS (TCP 2049) from the VPC CIDR."
  type        = string
}

variable "management_subnet_id" {
  description = "Subnet ID for the management subnet (us-west-2a). One EFS mount target here serves all us-west-2a subnets (management, onprem, cloud-a)."
  type        = string
}

variable "cloud_subnet_b_id" {
  description = "Subnet ID for cloud burst subnet B (us-west-2b). Mount target here serves burst nodes launched in AZ-B."
  type        = string
}
