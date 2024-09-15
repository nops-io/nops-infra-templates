provider "aws" {
  region = var.region
}

# This next section of code configures the AWS provider to interact with AWS services, specifically in the “us-east-1” region. 
# This provider is used to manage AWS resources such as ECR, IAM roles and more.
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

# This configures the Kubernetes provider to interact with the Kubernetes API server. 
# It uses the AWS CLI to authenticate with the EKS cluster by generating a token.
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

# Next, we configure the Helm provider to manage Helm charts in the Kubernetes cluster. 
# This uses the AWS CLI to authenticate with the EKS cluster, similar to the Kubernetes provider. 
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

# We now configure the kubectl provider to apply Kubernetes manifests using ‘kubectl’.
# This provider is useful for directly managing Kubernetes resources through Terraform. 
provider "kubectl" {
  apply_retry_count      = 5
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  load_config_file       = false

  # Uses AWS CLI for EKS authentication.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
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

# The following adds an access entry for Karpenter node IAM roles in the EKS cluster's ConfigMap. 
# This resource should be used if the cluster is configured with Authentication mode set to "EKS API and ConfigMap." 
# If not use the module aws-auth to add the entry to the configmap.
resource "aws_eks_access_entry" "karpenter_node_access_entry" {
  cluster_name      = var.cluster_name
  principal_arn     = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  kubernetes_groups = []
  type              = "EC2_LINUX"
}
#module "aws-auth" {
#  source  = "terraform-aws-modules/eks/aws//modules/aws-auth"
#  version = "20.14.0"
#
#  manage_aws_auth_configmap = true
#
#  aws_auth_roles = [
#    {
#      rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
#      username = "system:node:{{EC2PrivateDNSName}}"
#      groups   = ["system:bootstrappers","system:nodes"]
#    },
#  ]
#}


# The following configures the Karpenter add-on, including the Helm chart version and credentials for accessing the public ECR repository. 
module "eks_blueprints_addons" {
  source = "aws-ia/eks-blueprints-addons/aws"
  version = "1.16.3" #ensure to update this to the latest/desired version
  
  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  enable_karpenter        = true

  karpenter = {
    chart_version              = "0.36.2"
    repository_username        = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password        = data.aws_ecrpublic_authorization_token.token.password
  }

  # Ensures the IAM role for Karpenter nodes has a static name to align with the Karpenter manifest configuration.
  karpenter_node = {
    iam_role_use_name_prefix = false
  }
}

# EC2NodeClass CRD for Karpenter, which defines the configuration for the EC2 instances that will be managed by Karpenter in the cluster. 
# This CRD includes specifications like AMI family, IAM role, and subnet/security group selectors.
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2
      role: ${module.eks_blueprints_addons.karpenter.node_iam_role_name}
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
    module.eks_blueprints_addons
  ]
}

# The following deploys the NodePool CRD for Karpenter, which defines the scaling policies and instance selection criteria for nodes in the Kubernetes cluster. 
# This CRD includes limits on the total CPU and specifies disruption policies for node consolidation.
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
              values: ["4", "8", "16", "32"]
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
    kubectl_manifest.karpenter_node_class
  ]
}

# This deploys an example Kubernetes Deployment to demonstrate Karpenter's ability  to dynamically scale nodes based on workload demands. 
# The deployment uses a simple container image and sets replicas to zero initially to prevent resource allocation.
resource "kubectl_manifest" "karpenter_example_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: inflate
    spec:
      replicas: 0
      selector:
        matchLabels:
          app: inflate
      template:
        metadata:
          labels:
            app: inflate
        spec:
          terminationGracePeriodSeconds: 0
          containers:
            - name: inflate
              image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
              resources:
                requests:
                  cpu: 1
        topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values:
              - "inflate" 
  YAML

  depends_on = [
    module.eks_blueprints_addons
  ]
}
