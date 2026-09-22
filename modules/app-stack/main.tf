###############################################################################
# app-stack
#
# One opinionated composite module: a Container App fronting a private
# Postgres Flexible Server, authenticated with a user-assigned managed
# identity and Entra ID tokens. There is no database password anywhere.
#
# Ordering that matters (and that breaks silently if you get it wrong):
#   1. Private DNS zone must be linked to the VNet BEFORE the Postgres server
#      is created, or the app resolves the public name and cannot connect.
#   2. The Postgres delegated subnet must be empty at creation and cannot be
#      re-delegated afterwards.
#   3. The Container App environment must declare its workload profile
#      explicitly, or Azure's implicit default shows as a perpetual diff on
#      every subsequent plan.
#
# Key Vault was tried and removed. See the note above the Postgres server.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Globally-unique names need a deterministic suffix.
  suffix = substr(sha1("${var.name}-${var.environment}-${data.azurerm_client_config.current.subscription_id}"), 0, 6)

  apps_subnet_cidr = cidrsubnet(var.vnet_address_space, 7, 0) # /23 when vnet is /16
  db_subnet_cidr   = cidrsubnet(var.vnet_address_space, 8, 2) # /24 when vnet is /16

  # A registry credential is configured only when BOTH a username and a
  # password are supplied. Either both or neither - a half-configured
  # credential is always an error, never a valid intermediate state.
  use_registry_credential = var.registry_username != "" && var.registry_password != ""

  # What the migrate init container needs to reach Postgres. The app container
  # sets the same values explicitly below; keep the two in step.
  database_env = {
    PGHOST          = azurerm_postgresql_flexible_server.this.fqdn
    PGDATABASE      = var.database_name
    PGUSER          = azurerm_user_assigned_identity.app.name
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.app.client_id
  }

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

# NOTE: there is deliberately no password anywhere in this module.
#
# Postgres is configured for Entra ID authentication ONLY. The application's
# managed identity is the database administrator, and the app obtains a
# short-lived token at connect time. Consequences:
#
#   - no credential in Terraform state, Key Vault, or a Container App secret
#   - nothing for `terraform plan` to read, so plan works under a read-only
#     identity (the previous designs failed on Key Vault getSecret and then
#     on Container Apps listSecrets - the same problem twice, because the
#     secret still existed)
#   - credentials rotate hourly on their own
#
# This is the third iteration of this decision. The first two moved the
# secret; only removing it actually solved the problem.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${local.base}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  version               = var.postgres_version
  sku_name              = var.postgres_sku
  storage_mb            = var.postgres_storage_mb
  backup_retention_days = var.postgres_backup_retention_days
  zone                  = "1"

  # Private access: no public endpoint, VNet-integrated.
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.database.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id

  # Entra ID only. With password_auth_enabled = false, administrator_login
  # and administrator_password are omitted entirely - there is no local admin
  # account to leak.
  authentication {
    password_auth_enabled         = false
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

# The app's managed identity IS the database administrator. For the POC this
# is deliberately coarse - a real deployment would create a least-privilege
# role via SQL. But it means the app can authenticate with a token and no
# password exists anywhere in the system.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "app" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.app.principal_id
  principal_name      = azurerm_user_assigned_identity.app.name
  principal_type      = "ServicePrincipal"
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
# Database connection string
#
# Deliberately NOT stored in Key Vault, after the POC showed what that cost.
#
# The original design put the connection string in a Key Vault secret and had
# the container app resolve it via a Key Vault reference. That is the textbook
# shape, and it was wrong here for three reasons:
#
#  1. `azurerm_key_vault_secret` requires a DATA-PLANE read on every refresh.
#     The plan identity is Reader-only by design, so every plan failed with
#     ForbiddenByRbac. Fixing that means granting the plan identity permission
#     to read secrets - while it runs Terraform against unreviewed PR content.
#     That is a materially worse security position than the one Key Vault was
#     supposed to provide.
#  2. It bought nothing in practice. Terraform constructs the connection
#     string, so the value is in Terraform state either way. Key Vault was
#     protecting a secret that was already written to the state blob.
#  3. It cost a 60-second RBAC propagation sleep, two role assignments, and a
#     vault whose soft-delete complicates teardown.
#
# The connection string is now passed directly as a Container App secret.
# Container App secrets are write-only through the API, so no data-plane read
# is needed and plan works under a read-only identity.
#
# For the real product, where secrets should be rotatable independently of
# Terraform, revisit this - but solve it by taking the value out of Terraform
# entirely, not by putting Key Vault back in front of a value Terraform
# already knows.
###############################################################################


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

  # Azure adds a default "Consumption" workload profile whether or not one is
  # declared. Leaving it out made every subsequent plan show an in-place
  # update removing it - a perpetual diff that has nothing to do with the
  # change being deployed, and which would make the "a redeploy is a one-line
  # diff" property untrue in practice.
  #
  # Declaring it explicitly makes the config match reality.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }

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

  # No database secret exists. The app authenticates to Postgres with an
  # Entra token from its managed identity at connect time.
  #
  # Beware when extending this module: adding ANY secret here reintroduces
  # the plan-time 403, because the provider calls
  # Microsoft.App/containerApps/listSecrets on refresh and the plan identity
  # is Reader-only. The registry credential below is the one remaining case,
  # and it exists only when pulling from a private registry.

  # Gate on the PASSWORD, not the username.
  #
  # Keying this off registry_username meant that setting a username without a
  # password produced a secret with an empty value, which Azure rejects with
  # ContainerAppSecretInvalid ("value or keyVaultUrl and identity should be
  # provided") - roughly eight minutes into an apply, after Postgres has
  # already been built. The precondition below turns that into a plan-time
  # error instead.
  dynamic "secret" {
    for_each = local.use_registry_credential ? [1] : []
    content {
      name  = "registry-password"
      value = var.registry_password
    }
  }

  dynamic "registry" {
    for_each = local.use_registry_credential ? [1] : []
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

    # Schema migrations, run before the app container in every new replica.
    #
    # Same image, started with the single argument `migrate` - part of the image
    # contract, see README. The app container starts only if this exits 0, and
    # in Single revision mode a revision that never becomes ready takes no
    # traffic, so a failed migration leaves the previous revision serving.
    # (Unverified at min_replicas = 0 - see README, "Known behaviours".)
    # Replicas starting together are safe: the migration tool locks the history
    # table, so each migration applies exactly once and the rest are no-ops.
    #
    # This is the one place in the stack allowed to need the database at
    # startup. The app container's /health contract is unchanged.
    #
    # Needs the managed identity at run time. Init containers only get it in a
    # workload-profile environment on a Consumption profile (identity
    # lifecycle defaults to All) - which is what the environment above
    # declares. Moving to a Consumption-only or Dedicated environment would
    # break this silently: the init container would fail to get a token.
    #
    # 0.25 vCPU / 0.5Gi is valid whether or not the platform counts init
    # containers toward the app's resource total: every app size here plus
    # this is still an allowed combination.
    init_container {
      name   = "migrate"
      image  = var.container_image
      args   = ["migrate"]
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = local.database_env
        content {
          name  = env.key
          value = env.value
        }
      }
    }

    container {
      name   = var.name
      image  = var.container_image
      cpu    = var.cpu
      memory = var.memory

      # Connection details, not credentials. The app combines these with a
      # token from its managed identity - see AGENT.md in the app template.
      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.this.fqdn
      }

      env {
        name  = "PGDATABASE"
        value = var.database_name
      }

      # Entra principal name of the managed identity, used as the Postgres
      # username.
      env {
        name  = "PGUSER"
        value = azurerm_user_assigned_identity.app.name
      }

      # Required so DefaultAzureCredential picks the USER-assigned identity
      # rather than searching for a system-assigned one.
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
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

    precondition {
      # Catches the missing-secret case at plan time rather than eight
      # minutes into an apply.
      condition     = var.registry_username == "" || var.registry_password != ""
      error_message = "registry_username is set to \"${var.registry_username}\" but registry_password is empty. Either set the GHCR_READ_TOKEN secret on the deployments repo (it is passed as TF_VAR_registry_password), or make the container package public and set registry_username to \"\" in terraform.tfvars.json."
    }

    precondition {
      condition     = var.registry_password == "" || var.registry_username != ""
      error_message = "registry_password is set but registry_username is empty. Both are required to configure a private registry pull, or neither."
    }
  }

}
