terraform {
  required_version = "~> 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # NOTE: Backend configuration cannot reference variables/resources.
    bucket         = "gringotts-tf-state-641332413762"
    key            = "infrastructure/us-west-2/dev.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "gringotts-lock-table"
  }
}


