#!/bin/bash
# Build and push Docker image to ECR
# Usage: ./scripts/build-and-push.sh [tag]

set -e

AWS_REGION="us-west-2"
AWS_ACCOUNT_ID="641332413762"
ECR_REPO_NAME="gringotts-clearinghouse-dev-app"
IMAGE_TAG="${1:-latest}"

ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

echo "=== Building Docker image ==="
docker build -t ${ECR_REPO_NAME}:${IMAGE_TAG} .
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} ${ECR_REPO_URI}:${IMAGE_TAG}
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} ${ECR_REPO_URI}:latest

echo "=== Logging into ECR ==="
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REPO_URI}

echo "=== Pushing image to ECR ==="
docker push ${ECR_REPO_URI}:${IMAGE_TAG}
docker push ${ECR_REPO_URI}:latest

echo "=== Successfully pushed ${ECR_REPO_URI}:${IMAGE_TAG} ==="

