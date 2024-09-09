# main.tf

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

# This next section of code configures the AWS provider to interact with AWS services, specifically in the “us-east-1” region. 
# This provider is used to manage AWS resources such as ECR, IAM roles and more.
provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

# Now, we retrieve an authorization token to access the public Amazon ECR registry. This is required to pull container images. 
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

# The node group will container EC2 instances that are part of the Kubernetes cluster.
# The node group is configured with specific instance types, disk sizes, and taints. 
module "eks_managed_node_group" {
  source = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "20.14.0"

  name            = var.eks_managed_node_group_name
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  subnet_ids = var.subnet_ids

  cluster_primary_security_group_id = var.cluster_primary_security_group_id
  cluster_service_cidr = var.cluster_service_cidr

  iam_role_use_name_prefix = false
  
  use_custom_launch_template = false
  disk_size = 50

  min_size     = 2
  max_size     = 3
  desired_size = 2

  instance_types = ["m5.large"]
  capacity_type  = "ON_DEMAND"

  taints = {
    dedicated = {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  tags = var.tags
}

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

  depends_on = [
    module.eks_managed_node_group
  ]
}

# Use this resource if you have Access configuration with Authentication mode set as EKS API and ConfigMap,
# if not add the manual entry to the aws-auth configmap.
#resource "aws_eks_access_entry" "karpenter_node_access_entry" {
#  cluster_name      = var.cluster_name
#  principal_arn     = module.eks_blueprints_addons.karpenter.node_iam_role_arn
#  kubernetes_groups = []
#  type              = "EC2_LINUX"
#}

module "aws-auth" {
  source  = "terraform-aws-modules/eks/aws//modules/aws-auth"
  version = "20.14.0"

  manage_aws_auth_configmap = true

  # The following maps the IAM role created for Karpenter nodes to the necessary Kubernetes groups.
  # This allows Karpenter nodes to be recognized as part of the Kubernetes cluster. 
  aws_auth_roles = [
    {
      rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers","system:nodes"]
    },
  ]
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
