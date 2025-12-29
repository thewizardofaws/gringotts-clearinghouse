########################################
# Guardrails Module
# Implements "Data SRE" approach with least privilege IAM
# and human-in-the-loop approval gates for Agent operations
########################################

# IAM Policy for Agent with Least Privilege (Read-Only S3, No Delete)
data "aws_iam_policy_document" "agent_readonly_s3" {
  statement {
    sid    = "AllowS3ReadOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*"
    ]
  }
  
  # Explicitly deny delete operations
  statement {
    sid    = "DenyS3Delete"
    effect = "Deny"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutObjectTagging",
      "s3:DeleteObjectTagging"
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "agent_readonly_s3" {
  name        = "${var.project_name}-${var.environment}-agent-readonly-s3-policy"
  path        = "/interview/"
  description = "Least privilege policy for Agent: S3 Read-Only access, no delete permissions"
  policy      = data.aws_iam_policy_document.agent_readonly_s3.json

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${var.environment}-agent-readonly-s3-policy"
    Purpose     = "AgentGuardrails"
    LeastPrivilege = "true"
  })
}

# IAM Role for Agent (assumes role will be assumed by Agent service/user)
# Note: Trust policy should be configured based on how Agent authenticates
data "aws_iam_policy_document" "agent_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    
    # Placeholder: Update with actual principal that Agent uses
    # Examples: specific IAM user, service account, or external identity
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]  # Placeholder - update as needed
    }
    
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-west-2"]  # Restrict to specific region
    }
  }
}

resource "aws_iam_role" "agent_role" {
  name                 = "${var.project_name}-${var.environment}-agent-role"
  path                 = "/interview/"
  permissions_boundary = "arn:aws:iam::641332413762:policy/InterviewCandidatePolicy"
  assume_role_policy   = data.aws_iam_policy_document.agent_assume_role.json

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${var.environment}-agent-role"
    Purpose     = "AgentGuardrails"
    LeastPrivilege = "true"
  })
}

resource "aws_iam_role_policy_attachment" "agent_readonly_s3" {
  role       = aws_iam_role.agent_role.name
  policy_arn = aws_iam_policy.agent_readonly_s3.arn
}

# SNS Topic for Manual Approval (Human-in-the-Loop Gate)
resource "aws_sns_topic" "manual_approval" {
  name         = "${var.project_name}-${var.environment}-agent-approval"
  display_name = "Agent IaC Change Approval"
  
  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-agent-approval"
    Purpose = "HumanInTheLoop"
  })
}

# SNS Topic Subscription (placeholder - configure with actual email/endpoint)
# Uncomment and configure when ready to use
# resource "aws_sns_topic_subscription" "manual_approval_email" {
#   topic_arn = aws_sns_topic.manual_approval.arn
#   protocol  = "email"
#   endpoint  = "data-sre-team@example.com"  # Update with actual email
# }

