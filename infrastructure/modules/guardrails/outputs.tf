output "agent_role_arn" {
  description = "ARN of the IAM role for Agent with least privilege permissions"
  value       = aws_iam_role.agent_role.arn
}

output "agent_role_name" {
  description = "Name of the IAM role for Agent"
  value       = aws_iam_role.agent_role.name
}

output "manual_approval_topic_arn" {
  description = "ARN of the SNS topic for manual approval of Agent IaC changes"
  value       = aws_sns_topic.manual_approval.arn
}

output "manual_approval_topic_name" {
  description = "Name of the SNS topic for manual approval"
  value       = aws_sns_topic.manual_approval.name
}

