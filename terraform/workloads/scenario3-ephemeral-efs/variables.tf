variable "gen_state_path" {
  description = "Path to the generation cluster's terraform.tfstate"
  type        = string
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "aws_profile" {
  type    = string
  default = "aws"
}

variable "cluster_name" {
  type    = string
  default = "burstlab-gen1"
}
