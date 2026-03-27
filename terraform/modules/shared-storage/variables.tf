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
  description = "Subnet ID for the management subnet (head node). An EFS mount target is placed here so the head node can mount EFS locally (fast path, no cross-AZ traffic)."
  type        = string
}

variable "onprem_subnet_id" {
  description = "Subnet ID for the on-prem compute subnet. EFS mount target here serves compute01-04 with low-latency NFS access."
  type        = string
}

variable "cloud_subnet_a_id" {
  description = "Subnet ID for cloud burst subnet A. Burst nodes in us-west-2a use this mount target to avoid cross-AZ NFS traffic (latency + cost)."
  type        = string
}

variable "cloud_subnet_b_id" {
  description = "Subnet ID for cloud burst subnet B (us-west-2b). Mount target here serves burst nodes launched in AZ-B."
  type        = string
}
