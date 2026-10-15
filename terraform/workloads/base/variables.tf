# =============================================================================
# BASE WORKLOADS LAYER — Variables
# =============================================================================
# These variables are shared across all workload scenario overlays.
# The gen_state_path and key_path MUST be set — no defaults.

variable "gen_state_path" {
  description = "Path to the deployed generation cluster's terraform.tfstate file. Relative to this directory, e.g. ../../generations/gen1-slurm2205-rocky8/terraform.tfstate"
  type        = string
}

variable "key_path" {
  description = "Path to the SSH private key file for connecting to the head node (e.g. ~/.ssh/burstlab-key.pem)"
  type        = string
}

variable "aws_region" {
  description = "AWS region. Defaults to the generation cluster's region (read from gen_state_path); set only to override."
  type        = string
  default     = null
}

variable "aws_profile" {
  description = "AWS CLI named profile. Replace 'aws' with your actual profile name."
  type        = string
  default     = "aws"
}

variable "cluster_name" {
  description = "Cluster name. Defaults to the generation cluster's cluster_name (read from gen_state_path); set only to override."
  type        = string
  default     = null
}
