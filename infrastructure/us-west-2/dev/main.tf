provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      CandidateId = "kc-tyler-001"
      Project     = "gringotts-clearinghouse"
      Environment = "dev"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix_raw = "${var.project_name}-${var.environment}"
  name_prefix_s3  = substr(replace(lower(local.name_prefix_raw), "/[^a-z0-9-]/", "-"), 0, 32)

  eks_cluster_name = "${var.project_name}-${var.environment}-eks"
  vpc_name         = "${var.project_name}-${var.environment}-vpc"

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = {
    CandidateId = "kc-tyler-001"
    Project     = var.project_name
    Environment = var.environment
  }
}

########################################
# Network (VPC)
########################################

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true # Required for EKS
  enable_dns_hostnames = true # Required for EKS

  tags = {
    Name = "gringotts-clearinghouse-dev-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name        = "${local.vpc_name}-igw"
    CandidateId = "kc-tyler-001"
  }
}

resource "aws_subnet" "public" {
  for_each = {
    for idx, az in local.azs : az => {
      az  = az
      cid = cidrsubnet(aws_vpc.this.cidr_block, 4, idx)
    }
  }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.az
  cidr_block              = each.value.cid
  map_public_ip_on_launch = true

  tags = {
    Name                                              = "${local.vpc_name}-public-${each.value.az}"
    CandidateId                                       = "kc-tyler-001"
    "kubernetes.io/role/elb"                          = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "owned"
  }
}

resource "aws_subnet" "private" {
  for_each = {
    for idx, az in local.azs : az => {
      az  = az
      cid = cidrsubnet(aws_vpc.this.cidr_block, 4, idx + 8)
    }
  }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.value.az
  cidr_block        = each.value.cid

  tags = {
    Name                                              = "${local.vpc_name}-private-${each.value.az}"
    CandidateId                                       = "kc-tyler-001"
    "kubernetes.io/role/internal-elb"                 = "1"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "owned"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name        = "${local.vpc_name}-public-rt"
    CandidateId = "kc-tyler-001"
  }
}

resource "aws_route" "public_inet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name        = "${local.vpc_name}-nat-eip"
    CandidateId = "kc-tyler-001"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id

  tags = {
    Name        = "${local.vpc_name}-nat"
    CandidateId = "kc-tyler-001"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name        = "${local.vpc_name}-private-rt"
    CandidateId = "kc-tyler-001"
  }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

########################################
# Security Groups (EKS + RDS)
########################################

# The Cluster Security Group (Keep it empty of inline rules)
resource "aws_security_group" "eks_cluster" {
  name        = "gringotts-clearinghouse-dev-eks-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "gringotts-clearinghouse-dev-eks-cluster-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# The Node Security Group
resource "aws_security_group" "eks_nodes" {
  name        = "gringotts-clearinghouse-dev-eks-nodes-sg"
  description = "EKS worker nodes security group"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.common_tags, { Name = "gringotts-clearinghouse-dev-eks-nodes-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Handshake Rules as standalone resources
resource "aws_security_group_rule" "nodes_to_cluster" {
  description              = "Allow nodes to communicate with the cluster API"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster_to_nodes" {
  description              = "Allow cluster API to communicate with nodes"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  type                     = "ingress"
}

# Additional required rules
resource "aws_security_group_rule" "cluster_egress_all" {
  description       = "Allow all egress from cluster"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_security_group_rule" "nodes_egress_all" {
  description       = "Allow all egress from nodes"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_security_group_rule" "nodes_ingress_self" {
  description       = "Allow node to node all traffic"
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_security_group_rule" "cluster_ingress_workstation" {
  description = "Allow local workstation to talk to EKS API"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  # FIX: Reference the resource ID, not a hardcoded string
  security_group_id = aws_security_group.eks_cluster.id
  type              = "ingress"
}

########################################
# IAM Roles (path = /interview/)
########################################

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name                 = "eks-control-plane-role"
  path                 = "/interview/"
  permissions_boundary = "arn:aws:iam::641332413762:policy/InterviewCandidatePolicy"
  assume_role_policy   = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSVPCResourceController" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

data "aws_iam_policy_document" "eks_nodes_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name                 = "eks-node-role"
  path                 = "/interview/"
  permissions_boundary = "arn:aws:iam::641332413762:policy/InterviewCandidatePolicy"
  assume_role_policy   = data.aws_iam_policy_document.eks_nodes_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_nodes_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

########################################
# Compute (EKS)
########################################

resource "aws_eks_cluster" "this" {
  name     = local.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat([for s in aws_subnet.private : s.id], [for s in aws_subnet.public : s.id])
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSVPCResourceController,
  ]
}

resource "aws_launch_template" "eks_nodes" {
  name = "eks-nodes-lt"

  # the Node Security Group so nodes can talk to the cluster
  vpc_security_group_ids = [aws_security_group.eks_nodes.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(<<EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY"

--BOUNDARY
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${aws_eks_cluster.this.name}
    apiServerEndpoint: ${aws_eks_cluster.this.endpoint}
    certificateAuthority: ${aws_eks_cluster.this.certificate_authority[0].data}
    cidr: ${aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr}
--BOUNDARY--
EOT
  )
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "gringotts-clearinghouse-dev-eks-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [for s in aws_subnet.private : s.id]

  ami_type = "AL2023_x86_64_STANDARD"

  instance_types = ["t3.medium"]

  scaling_config {
    desired_size = 2
    max_size     = 10
    min_size     = 1
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks_nodes_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.eks_nodes_AmazonEC2ContainerRegistryReadOnly,
  ]
}


