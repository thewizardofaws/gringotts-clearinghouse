########################################
# Budget Alerts SNS Topic
# Manages SNS topic for AWS Budgets notifications
########################################

# SNS Topic for Budget Alerts
resource "aws_sns_topic" "budget_alerts" {
  name         = "interview-alerts-kc-tyler-001"
  display_name = "Interview Budget Alerts - kc-tyler-001"
  
  tags = merge(local.common_tags, {
    Name    = "interview-alerts-kc-tyler-001"
    Purpose = "BudgetAlerts"
  })
}

# SNS Topic Policy - Allow AWS Budgets to publish
data "aws_iam_policy_document" "budget_alerts_sns_policy" {
  # Default statement - allow account owner actions
  statement {
    sid    = "DefaultStatement"
    effect  = "Allow"
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish"
    ]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
    resources = [aws_sns_topic.budget_alerts.arn]
  }

  # Allow AWS Budgets service to publish
  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"
    actions = [
      "SNS:Publish"
    ]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.budget_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn    = aws_sns_topic.budget_alerts.arn
  policy = data.aws_iam_policy_document.budget_alerts_sns_policy.json
}

