#!/bin/bash
# Build and push Docker image to ECR
# Usage: ./scripts/build-and-push.sh [tag]

set -euo pipefail

# Configuration
AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-641332413762}"
ECR_REPO_NAME="gringotts-clearinghouse-dev-app"
IMAGE_TAG="${1:-latest}"

ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

# Validate prerequisites
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not in PATH" >&2
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI is not installed or not in PATH" >&2
    exit 1
fi

# Verify Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    echo "ERROR: Dockerfile not found in current directory" >&2
    exit 1
fi

echo "=== Building Docker image ==="
# Build for linux/amd64 platform to match EKS nodes
if ! docker build --platform linux/amd64 -t "${ECR_REPO_NAME}:${IMAGE_TAG}" .; then
    echo "ERROR: Docker build failed" >&2
    exit 1
fi

docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_REPO_URI}:${IMAGE_TAG}"
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${ECR_REPO_URI}:latest"

echo "=== Authenticating with ECR ==="
if ! aws ecr get-login-password --region "${AWS_REGION}" | \
     docker login --username AWS --password-stdin "${ECR_REPO_URI}"; then
    echo "ERROR: ECR authentication failed" >&2
    exit 1
fi

echo "=== Pushing image to ECR ==="
if ! docker push "${ECR_REPO_URI}:${IMAGE_TAG}"; then
    echo "ERROR: Failed to push image tag ${IMAGE_TAG}" >&2
    exit 1
fi

if ! docker push "${ECR_REPO_URI}:latest"; then
    echo "ERROR: Failed to push latest tag" >&2
    exit 1
fi

echo "=== Successfully pushed ${ECR_REPO_URI}:${IMAGE_TAG} ==="

