terraform {
  required_version = "~> 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Fixture used by CI to prove the module still plans. Not intended to be applied.
module "app" {
  source = "../../modules/app-stack"

  name            = "example"
  environment     = "dev"
  location        = "swedencentral"
  container_image = "ghcr.io/main0034/aaas-app-demo:bootstrap"

  cpu          = 0.25
  memory       = "0.5Gi"
  min_replicas = 0
  max_replicas = 2

  tags = {
    owner      = "martin"
    costCenter = "poc"
  }
}

output "app_url" {
  value = module.app.app_url
}
