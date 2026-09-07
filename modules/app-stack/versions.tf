terraform {
  required_version = "~> 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    # No random provider: there is no password to generate. See the note
    # above azurerm_postgresql_flexible_server in main.tf.
  }
}
