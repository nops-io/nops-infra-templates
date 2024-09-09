# How to migrate from Cluster Autoscaler to Karpenter using Fargate

Configuration in this directory creates a Fargate Profile to run [Karpenter](https://karpenter.sh/) and used to provision and manage compute resource scaling. In the example provided, is assumed that an EKS cluster is already created and using [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler) is useed to scale and manage nodes.

*Note: The following migration guide was composed by taking inspiration from the EKS Terraform AWS Modules, more info [here](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/20.14.0)*
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.40 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 2.7 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 2.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.40 |
| <a name="provider_aws.virginia"></a> [aws.virginia](#provider\_aws.virginia) | >= 5.40 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 2.7 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 2.0 |

## AWS Resources
- VPC, Subnets, Security Group(s)
- EKS Cluster

## Tagging Resources

As part of the Karpenter migration, Subnets (Typically Private subnets) where you will run your worker nodes, and Security Group(s) that are attached to your worker nodes need to be tagged accordingly with a specific key, value:

```bash
karpenter.sh/discovery: <your_cluster_name>
```

## Usage

*Note: The following terraform files make use of variables inputs, populate them with your own values accordingly.*

To provision the resources of the module, position in the folder/directory where you have all the Terraform files and execute the following commands:

```bash
terraform init
terraform plan
terraform apply
```

Once the Terraform apply command finishes successfully, the following command can be used to list the pods in the Karpenter namespace, and you should see 2 running pods:

```bash
kubectl -n karpenter get pods
```

New CRDs (EC2NodeClass and NodePool) have been created as part of the Karpenter installation; run the following commands to view the new resources:

```bash
kubectl get ec2nodeclass
kubectl get nodepool
```

As part of this installation, you will receive a sample deployment application. You can increase the number of replicas to see Karpenter in action as it spins up new nodes for the upcoming pods. To do this, run the following command:

```text
kubectl -n default scale deploy inflate --replicas=20
```

To verify that the new pods are running, run the following command:

```sh
kubectl -n default get pods
```

To verify that Karpenter is creating new nodes, run the following command to list Karpenter provisioned nodes; you should see nodes with a status of True.

```text
kubectl get nodeclaim
```

Once you've verified that Karpenter is running and provisioning nodes effectively, you can remove Cluster Autoscaler. First, identify all the nodes provisioned by Cluster Autoscaler, cordon each of them, and then drain them one by one. This prevents pods from being rescheduled onto Cluster Autoscaler nodes, allowing Karpenter to provision new nodes for your workloads instead.

```text
kubectl get nodes
kubectl cordon <your_node_name>
kubectl drain <your_node_name> --ignore-daemonsets --delete-emptydir-data
```

After moving all pod workloads to Karpenter-provisioned nodes, you can remove/disable Cluster Autoscaler by setting the deployment replicas to zero, running the following command:

```text
kubectl -n kube-system scale deploy/cluster-autoscaler --replicas=0
```