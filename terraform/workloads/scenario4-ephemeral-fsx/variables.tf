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

variable "create_fsx_service_linked_role" {
  description = "Set to false if the AWSServiceRoleForAmazonFSx role already exists in your account (it is account-scoped and only needs to be created once)"
  type        = bool
  default     = true
}

variable "create_fsx_s3_service_linked_role" {
  description = "Set to false if the s3.data-source.lustre.fsx.amazonaws.com service-linked role already exists in your account (required for FSx S3 data repositories)"
  type        = bool
  default     = true
}
