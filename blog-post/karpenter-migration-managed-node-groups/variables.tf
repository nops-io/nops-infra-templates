variable cluster_name {
  type        = string
  default     = ""
  description = "The name of the EKS cluster. This is used to identify the cluster in AWS and is referenced in various Karpenter and EKS configurations."
}

variable cluster_endpoint {
  type        = string
  default     = ""
  description = "The endpoint URL of the EKS cluster. This is used by the Kubernetes, Helm, and Kubectl providers to communicate with the cluster."
}

variable cluster_version {
  type        = number
  description = "The version of Kubernetes to use for the EKS cluster. This is important for ensuring compatibility with Karpenter and other add-ons."
}

variable cluster_certificate_authority_data {
  type        = string
  description = "The certificate authority data for the EKS cluster. This is used to authenticate the connection to the cluster's API server."
}

variable oidc_provider_arn {
  type        = string
  default     = ""
  description = "The ARN of the OIDC provider associated with the EKS cluster. This is required for configuring Karpenter and other IAM roles for service accounts."
}

variable enable_karpenter  {
  type        = bool
  default     = true
  description = "A flag to enable or disable the deployment of Karpenter. When set to true, Karpenter will be deployed and configured in the EKS cluster."
}

variable eks_managed_node_group_name {
  type        = string
  description = "The name of the EKS managed node group. This is used to define and manage the worker nodes in the EKS cluster."
}

variable subnet_ids {
  type        = list(string)
  description = "A list of subnet IDs where the EKS cluster's worker nodes will be deployed. These subnets must be associated with the EKS cluster's VPC."
}

variable cluster_primary_security_group_id {
  type        = string
  description = "The ID of the primary security group associated with the EKS cluster. This security group is used for the cluster's communication and traffic management."
}

variable cluster_service_cidr {
  type        = string
  description = "The service CIDR for the EKS cluster, which defines the IP range for services deployed within the cluster. This is used in network configuration."
}

variable "tags" {
  type        = map(string)
  description = "A map of tags to apply to resources created by this module. These tags help categorize and manage resources in AWS."
}
