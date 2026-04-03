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

variable "roda_bucket" {
  description = "RODA S3 bucket to read from (e.g. noaa-goes16, usgs-landsat). Must be in the same region or publicly accessible."
  type        = string
  default     = "noaa-goes16"
}
