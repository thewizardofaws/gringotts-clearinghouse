########################################
# EKS Addons for Cluster Functionality
########################################

# Metrics Server - Required for resource utilization visibility in EKS Console
resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "metrics-server"

  # Ensure cluster is fully ready before installing addon
  depends_on = [
    aws_eks_node_group.this,
    aws_eks_cluster.this
  ]

  tags = merge(local.common_tags, {
    Name = "${local.eks_cluster_name}-metrics-server"
  })
}

