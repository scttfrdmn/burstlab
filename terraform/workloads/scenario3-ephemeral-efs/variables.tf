variable "gen_state_path" {
  description = "Path to the generation cluster's terraform.tfstate"
  type        = string
}

variable "aws_region" {
  description = "AWS region. Defaults to the generation cluster's region (read from gen_state_path); set only to override."
  type        = string
  default     = null
}

variable "aws_profile" {
  type    = string
  default = "aws"
}

variable "cluster_name" {
  description = "Cluster name. Defaults to the generation cluster's cluster_name (read from gen_state_path); set only to override."
  type        = string
  default     = null
}
