variable "project_name" {
  description = "Project/name prefix used for resource naming."
  type        = string
  default     = "gringotts-clearinghouse"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_desired_count" {
  description = "Desired node count for the EKS managed node group."
  type        = number
  default     = 2
}

variable "node_min_count" {
  description = "Minimum node count for the EKS managed node group."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum node count for the EKS managed node group. Interview constraint: <= 10."
  type        = number
  default     = 10
  validation {
    condition     = var.node_max_count <= 10
    error_message = "node_max_count must be <= 10 (interview constraint)."
  }
}

variable "db_name" {
  description = "Postgres database name."
  type        = string
  default     = "clearinghouse"
}

variable "db_username" {
  description = "Postgres master username (avoid reserved usernames like 'postgres')."
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "Postgres master password."
  type        = string
  sensitive   = true
}

variable "db_allocated_storage" {
  description = "Allocated storage (GB) for the RDS instance."
  type        = number
  default     = 20
}


