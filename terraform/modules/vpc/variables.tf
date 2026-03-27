variable "cluster_name" {
  description = "Name prefix used for all resources. Keeps resources identifiable in shared AWS accounts."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the entire VPC. 10.0.0.0/16 gives 65,536 addresses — plenty of room for subnets, burst nodes, and future expansion."
  type        = string
  default     = "10.0.0.0/16"
}

variable "management_subnet_cidr" {
  description = "CIDR for the management subnet (head node). Placed in us-west-2a for simplicity. The head node lives here and has a public EIP."
  type        = string
  default     = "10.0.0.0/24"
}

variable "onprem_subnet_cidr" {
  description = "CIDR for the 'on-prem' compute subnet. Simulates the private compute network in a real HPC cluster. No public IPs — traffic goes through the head node NAT."
  type        = string
  default     = "10.0.1.0/24"
}

variable "cloud_subnet_a_cidr" {
  description = "CIDR for cloud burst subnet A (us-west-2a). Burst nodes land here when Slurm requests capacity in AZ-A."
  type        = string
  default     = "10.0.2.0/24"
}

variable "cloud_subnet_b_cidr" {
  description = "CIDR for cloud burst subnet B (us-west-2b). Second AZ improves burst capacity availability — EC2 spot/on-demand pools differ per AZ."
  type        = string
  default     = "10.0.3.0/24"
}

variable "az_a" {
  description = "Primary availability zone. Head node, on-prem compute, and EFS mount targets all anchor here."
  type        = string
  default     = "us-west-2a"
}

variable "az_b" {
  description = "Secondary availability zone. Used for cloud burst subnet B and an additional EFS mount target for redundancy."
  type        = string
  default     = "us-west-2b"
}
