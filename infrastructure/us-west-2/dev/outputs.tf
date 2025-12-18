output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "rds_endpoint" {
  description = "RDS endpoint address."
  value       = aws_db_instance.this.address
}

output "s3_raw_bucket_name" {
  description = "S3 bucket name for raw file storage."
  value       = aws_s3_bucket.raw.bucket
}

output "ecr_repository_url" {
  description = "ECR repository URL for the application container."
  value       = aws_ecr_repository.app.repository_url
}

output "app_service_account_role_arn" {
  description = "IAM role ARN for the application service account (IRSA)."
  value       = aws_iam_role.app_service_account.arn
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA."
  value       = aws_iam_openid_connect_provider.eks.arn
}

