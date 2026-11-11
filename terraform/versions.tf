terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Estado local: terraform/terraform.tfstate (no se versiona; contiene contraseñas).
}

# Credenciales: AWS_PROFILE (aws configure sso) y CLOUDFLARE_API_TOKEN, desde el entorno.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "cms"
      ManagedBy = "terraform"
    }
  }
}

provider "cloudflare" {}
