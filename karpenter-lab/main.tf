provider "aws" {
  region = var.region
}
provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}
terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
      version = "2.0.4"
    }
  }
}
provider "kubernetes" {
  host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}
provider "kubectl" {
  apply_retry_count      = 5
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}
provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", var.cluster_name]
    }
  }
}
module "eks_blueprints_addons_karpenter" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"
  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn
  enable_karpenter = true
  karpenter = {
    chart_version       = "1.0.0"
    namespace           = "karpenter"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }
  karpenter_node = {
    # Use static name so that it matches what is defined in `karpenter.yaml` example manifest
    iam_role_use_name_prefix = false
  }
}
resource "aws_eks_access_entry" "karpenter_node_access_entry" {
  cluster_name      = var.cluster_name
  principal_arn     = module.eks_blueprints_addons_karpenter.karpenter.node_iam_role_arn
  kubernetes_groups = []
  type              = "EC2_LINUX"
}
# Now, we retrieve an authorization token to access the public Amazon ECR registry. This is required to pull container images. 
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}
# Creates an EKS Fargate profile specifically for Karpenter in the "karpenter" namespace. 
# The profile defines the subnets where Karpenter pods will be scheduled.
resource "aws_eks_fargate_profile" "karpenter" {
  cluster_name           = var.cluster_name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.karpenter.arn
  subnet_ids             = var.subnet_ids
  selector {
    namespace = "karpenter"
  }
}
# IAM role for the EKS Fargate profile with a trust policy allowing the "eks-fargate-pods" service to assume it.
# This role is necessary for running Fargate pods within the EKS cluster.
resource "aws_iam_role" "karpenter" {
  name = "eks-fargate-profile"
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}
# The following attaches the "AmazonEKSFargatePodExecutionRolePolicy" managed policy to the IAM role. 
# This policy provides the necessary permissions for the Fargate pods to interact with AWS services.
resource "aws_iam_role_policy_attachment" "amazon_eks_fargate_pod_execution_role_rolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.karpenter.name
}
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      role: ${module.eks_blueprints_addons_karpenter.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags:
        karpenter.sh/discovery: ${var.cluster_name}
  YAML
  depends_on = [
    module.eks_blueprints_addons_karpenter
  ]
}
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            name: default
          requirements:
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c", "m", "r"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["4", "8", "16"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: Gt
              values: ["2"]
      limits:
        cpu: 1000
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML
  depends_on = [
    module.eks_blueprints_addons_karpenter
  ]
}
