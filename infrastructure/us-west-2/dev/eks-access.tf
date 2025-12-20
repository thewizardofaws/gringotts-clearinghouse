########################################
# EKS Access Entry for Console Visibility
# Grants IAM principal access to view cluster resources in AWS Console
########################################

# Access entry for the stakeholder IAM user
# Note: Access entry may already exist from bootstrap_cluster_creator_admin_permissions
# This resource will manage it explicitly
resource "aws_eks_access_entry" "stakeholder" {
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/kc-tyler-001"
  kubernetes_groups = []
  type              = "STANDARD"
}

# Associate view policy for console visibility (read-only access)
# This enables viewing resources in the EKS Console UI
resource "aws_eks_access_policy_association" "stakeholder_console_view" {
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  principal_arn = aws_eks_access_entry.stakeholder.principal_arn

  access_scope {
    type = "cluster"
  }
}

# Optional: If root account access is needed
# resource "aws_eks_access_entry" "root_account" {
#   cluster_name      = aws_eks_cluster.this.name
#   principal_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
#   kubernetes_groups = []
#   type              = "STANDARD"
# }
#
# resource "aws_eks_access_policy_association" "root_console_view" {
#   cluster_name   = aws_eks_cluster.this.name
#   policy_arn     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
#   principal_arn  = aws_eks_access_entry.root_account.principal_arn
#
#   access_scope {
#     type = "cluster"
#   }
# }

