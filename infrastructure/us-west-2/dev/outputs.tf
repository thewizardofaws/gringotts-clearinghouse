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


