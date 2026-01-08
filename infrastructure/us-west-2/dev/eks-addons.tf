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

# AWS Load Balancer Controller
# Note: The aws-load-balancer-controller addon is not available for Kubernetes 1.34
# It must be installed via Helm chart. Install manually using:
# helm repo add eks https://aws.github.io/eks-charts
# helm repo update
# helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
#   -n kube-system \
#   --set clusterName=gringotts-clearinghouse-dev-eks \
#   --set serviceAccount.create=false \
#   --set serviceAccount.name=aws-load-balancer-controller
# 
# Then create the IRSA service account with proper IAM permissions

