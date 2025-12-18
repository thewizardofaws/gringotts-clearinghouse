########################################
# IRSA (IAM Role for Service Accounts)
# Allows pods to access S3 and RDS
########################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, {
    Name = "${local.eks_cluster_name}-oidc"
  })
}

# IAM Policy for S3 access
data "aws_iam_policy_document" "app_s3_access" {
  statement {
    sid    = "AllowS3ReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "app_s3_access" {
  name        = "${var.project_name}-${var.environment}-app-s3-policy"
  path        = "/interview/"
  description = "Policy for application pods to access S3 raw bucket"
  policy      = data.aws_iam_policy_document.app_s3_access.json

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-app-s3-policy"
  })
}

# IAM Policy for RDS access (via Secrets Manager or direct connection)
# Note: RDS access is typically via network/security groups, but we can add
# additional permissions if using RDS Proxy or Secrets Manager
data "aws_iam_policy_document" "app_rds_access" {
  statement {
    sid    = "AllowRDSConnection"
    effect = "Allow"
    actions = [
      "rds-db:connect"
    ]
    resources = [
      "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.this.resource_id}/${var.db_username}"
    ]
  }
}

resource "aws_iam_policy" "app_rds_access" {
  name        = "${var.project_name}-${var.environment}-app-rds-policy"
  path        = "/interview/"
  description = "Policy for application pods to connect to RDS"
  policy      = data.aws_iam_policy_document.app_rds_access.json

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-app-rds-policy"
  })
}

# Combined policy document for the service account role
data "aws_iam_policy_document" "app_service_account_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:default:clearinghouse-app"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_service_account" {
  name                 = "${var.project_name}-${var.environment}-app-sa-role"
  path                 = "/interview/"
  permissions_boundary = "arn:aws:iam::641332413762:policy/InterviewCandidatePolicy"
  assume_role_policy   = data.aws_iam_policy_document.app_service_account_assume.json

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-app-sa-role"
  })
}

resource "aws_iam_role_policy_attachment" "app_s3_access" {
  role       = aws_iam_role.app_service_account.name
  policy_arn = aws_iam_policy.app_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "app_rds_access" {
  role       = aws_iam_role.app_service_account.name
  policy_arn = aws_iam_policy.app_rds_access.arn
}

data "aws_region" "current" {}

# Note: RDS IAM authentication requires enabling IAM database authentication on the RDS instance
# For now, we're using username/password authentication via security groups
# The RDS IAM policy is included for future use if IAM auth is enabled

