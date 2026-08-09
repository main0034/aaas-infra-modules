###############################################################################
# app-stack
#
# One opinionated composite module: a Container App fronting a private
# Postgres Flexible Server, with the connection string brokered through Key
# Vault and read by a user-assigned managed identity.
#
# Ordering that matters (and that breaks silently if you get it wrong):
#   1. Private DNS zone must be linked to the VNet BEFORE the Postgres server
#      is created, or the app resolves the public name and cannot connect.
#   2. The Postgres delegated subnet must be empty at creation and cannot be
#      re-delegated afterwards.
#   3. Key Vault RBAC assignments need a propagation delay before the secret
#      write succeeds - hence the time_sleep below. Removing it produces an
#      intermittent 403 on first apply.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Globally-unique names need a deterministic suffix.
  suffix = substr(sha1("${var.name}-${var.environment}-${data.azurerm_client_config.current.subscription_id}"), 0, 6)

  # Key Vault names are limited to 24 chars and cannot contain underscores.
  kv_name = substr("kv-${replace(var.name, "-", "")}-${local.suffix}", 0, 24)

  apps_subnet_cidr = cidrsubnet(var.vnet_address_space, 7, 0) # /23 when vnet is /16
  db_subnet_cidr   = cidrsubnet(var.vnet_address_space, 8, 2) # /24 when vnet is /16

  tags = merge(var.tags, {
    managedBy   = "terraform"
    module      = "app-stack"
    environment = var.environment
    deployment  = var.name
  })
}

###############################################################################
# Resource group
###############################################################################

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.base}"
  location = var.location
  tags     = local.tags
}

###############################################################################
# Networking
###############################################################################

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.base}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

# Container Apps requires a /23 minimum for a workload-profile environment.
resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.apps_subnet_cidr]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Must be empty at creation time and cannot be re-delegated later.
resource "azurerm_subnet" "database" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.db_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.base}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "link-${local.base}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

###############################################################################
# Postgres Flexible Server (private access only)
###############################################################################

resource "random_password" "postgres_admin" {
  length      = 32
  special     = true
  # Azure rejects several punctuation characters in the admin password.
  override_special = "!#$%*()-_=+[]{}<>:?"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${local.base}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  version                = var.postgres_version
  sku_name               = var.postgres_sku
  storage_mb             = var.postgres_storage_mb
  backup_retention_days  = var.postgres_backup_retention_days
  zone                   = "1"

  administrator_login    = "psqladmin"
  administrator_password = random_password.postgres_admin.result

  # Private access: no public endpoint, VNet-integrated.
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.database.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  tags = local.tags

  # Without this the server may be created before the zone link exists, and
  # the private FQDN will not resolve from inside the VNet.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  lifecycle {
    prevent_destroy = false # POC: allow teardown. Revisit before any real data lands.
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

###############################################################################
# Identity
###############################################################################

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

###############################################################################
# Key Vault
###############################################################################

resource "azurerm_key_vault" "this" {
  name                = local.kv_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization  = true
  purge_protection_enabled   = false # POC: allows clean teardown.
  soft_delete_retention_days = 7

  tags = local.tags
}

# The identity running Terraform needs data-plane rights to write the secret.
resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The app identity needs read access to resolve the Key Vault reference.
resource "azurerm_role_assignment" "kv_app_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Azure RBAC is eventually consistent. Without a pause the first secret write
# intermittently fails with 403.
resource "time_sleep" "kv_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.kv_deployer]
  create_duration = "60s"
}

resource "azurerm_key_vault_secret" "db_connection_string" {
  name         = "db-connection-string"
  key_vault_id = azurerm_key_vault.this.id

  value = format(
    "postgresql://%s:%s@%s:5432/%s?sslmode=require",
    "psqladmin",
    urlencode(random_password.postgres_admin.result),
    azurerm_postgresql_flexible_server.this.fqdn,
    var.database_name,
  )

  depends_on = [time_sleep.kv_rbac_propagation]
}

###############################################################################
# Observability
###############################################################################

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

###############################################################################
# Container App
###############################################################################

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.base}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  infrastructure_subnet_id       = azurerm_subnet.apps.id
  internal_load_balancer_enabled = false

  tags = local.tags
}

resource "azurerm_container_app" "this" {
  name                         = "ca-${local.base}"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Connection string is resolved from Key Vault at revision start using the
  # app identity. The value never appears in this repo or in plan output.
  secret {
    name                = "db-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.db_connection_string.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  dynamic "secret" {
    for_each = var.registry_username != "" ? [1] : []
    content {
      name  = "registry-password"
      value = var.registry_password
    }
  }

  dynamic "registry" {
    for_each = var.registry_username != "" ? [1] : []
    content {
      server               = var.registry_server
      username             = var.registry_username
      password_secret_name = "registry-password"
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.container_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = var.name
      image  = var.container_image
      cpu    = var.cpu
      memory = var.memory

      env {
        name        = "DATABASE_URL"
        secret_name = "db-connection-string"
      }

      env {
        name  = "PORT"
        value = tostring(var.container_port)
      }

      dynamic "env" {
        for_each = var.app_env
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health"
        initial_delay           = 10
        interval_seconds        = 30
        failure_count_threshold = 3
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = var.container_port
        path                    = "/health"
        interval_seconds        = 10
        failure_count_threshold = 3
      }
    }
  }

  lifecycle {
    precondition {
      # Container Apps only accepts memory equal to 2x cpu, expressed in Gi.
      condition     = var.memory == "${var.cpu * 2}Gi"
      error_message = "Container Apps requires memory to be exactly 2x cpu in Gi. cpu=${var.cpu} implies memory=\"${var.cpu * 2}Gi\"."
    }

    precondition {
      condition     = var.max_replicas >= var.min_replicas
      error_message = "max_replicas must be greater than or equal to min_replicas."
    }
  }

  depends_on = [azurerm_role_assignment.kv_app_reader]
}
