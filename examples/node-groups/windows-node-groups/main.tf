terraform {
  required_version = ">= 1.0.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.66.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.6.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.4.1"
    }
  }

  backend "local" {
    path = "local_tf_state/terraform-main.tfstate"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
  # Specify AZs to avoid EKS cluster creation error due to reduced capacity in an AZ.
  # Change the AZ names per capacity available in the region you selected.
  # https://aws.amazon.com/premiumsupport/knowledge-center/eks-cluster-creation-errors/
  filter {
    name   = "zone-name"
    values = ["us-west-2a", "us-west-2b", "us-west-2c"]
  }
}

data "aws_eks_cluster" "cluster" {
  name = module.eks-blueprints.eks_cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks-blueprints.eks_cluster_id
}

provider "aws" {
  region = local.region
}

provider "kubernetes" {
  experiments {
    manifest_resource = true
  }
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    token                  = data.aws_eks_cluster_auth.cluster.token
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  }
}

locals {
  tenant          = var.tenant      # AWS account name or unique id for tenant
  environment     = var.environment # Environment area eg., preprod or prod
  zone            = var.zone        # Environment with in one sub_tenant or business unit
  region          = "us-west-2"
  cluster_version = var.cluster_version

  vpc_cidr     = "10.1.0.0/16"
  vpc_name     = join("-", [local.tenant, local.environment, local.zone, "vpc"])
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name = join("-", [local.tenant, local.environment, local.zone, "eks"])

  terraform_version = "Terraform v1.0.1"
}

module "aws_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "v3.2.0"

  name = local.vpc_name
  cidr = local.vpc_cidr
  azs  = local.azs

  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  create_igw           = true
  enable_dns_hostnames = true
  single_nat_gateway   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }

}
#---------------------------------------------------------------
# Example to consume eks-blueprints module
#---------------------------------------------------------------
module "eks-blueprints" {
  source = "../../.."

  tenant            = local.tenant
  environment       = local.environment
  zone              = local.zone
  terraform_version = local.terraform_version

  # EKS Cluster VPC and Subnet mandatory config
  vpc_id             = module.aws_vpc.vpc_id
  private_subnet_ids = module.aws_vpc.private_subnets

  # EKS CONTROL PLANE VARIABLES
  cluster_version = local.cluster_version

  # EKS MANAGED NODE GROUP
  # with Spot instances
  managed_node_groups = {
    mng_spot_medium = {
      node_group_name = "mng-spot-med"
      capacity_type   = "SPOT"
      instance_types  = ["t3.medium", "t3a.medium"]
      subnet_ids      = module.aws_vpc.private_subnets
      desired_size    = "2"
      disk_size       = 30
    }
  }

  # SELF-MANAGED NODE GROUP with Windows support
  enable_windows_support = true

  self_managed_node_groups = {
    ng_od_windows = {
      node_group_name    = "ng-od-windows"
      launch_template_os = "windows"
      instance_type      = "m5n.large"
      subnet_ids         = module.aws_vpc.private_subnets
      min_size           = "2"
    }
  }
}

module "eks-blueprints-kubernetes-addons" {
  source = "../../../modules/kubernetes-addons"

  eks_cluster_id = module.eks-blueprints.eks_cluster_id

  # EKS Managed Add-ons
  enable_amazon_eks_vpc_cni    = true
  enable_amazon_eks_coredns    = true
  enable_amazon_eks_kube_proxy = true

  # K8s Add-ons
  # Ensure proper node assignment
  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller_helm_config = {
    set = [
      {
        name  = "nodeSelector.kubernetes\\.io/os"
        value = "linux"
      }
    ]
  }

  enable_metrics_server = true
  metrics_server_helm_config = {
    set = [
      {
        name  = "nodeSelector.kubernetes\\.io/os"
        value = "linux"
      }
    ]
  }

  enable_cluster_autoscaler = true
  cluster_autoscaler_helm_config = {
    set = [
      {
        name  = "nodeSelector.kubernetes\\.io/os"
        value = "linux"
      }
    ]
  }

  depends_on = [module.eks-blueprints.managed_node_groups]
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = module.eks-blueprints.configure_kubectl
}
