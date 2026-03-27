variable "cluster_name" {
  description = "Name prefix for IAM roles and policies. Makes resources identifiable in the AWS console."
  type        = string
}

# Note: burst_node_role_arn is NOT a variable here. The head node's PassRole
# policy references aws_iam_role.burst_node.arn directly, which is resolved
# within this module. Both roles are created in this module to avoid any
# cross-module circular dependency.
