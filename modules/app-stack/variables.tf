###############################################################################
# app-stack input variables
#
# EVERY variable here is part of the agent-facing contract. Any variable that
# can take an unbounded value MUST have a validation block. This is the
# cheapest and most effective guardrail in the whole system: bad agent output
# is rejected here, before Terraform plans and long before Azure is called.
#
# If you add a variable, add a validation block and update:
#   - modules/app-stack/README.md
#   - aaas-deployments/schemas/app-stack.schema.json
###############################################################################

variable "name" {
  description = "Deployment slug. Drives all resource names. Lowercase alphanumeric and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", var.name))
    error_message = "name must be 3-22 chars, lowercase alphanumeric or hyphen, starting with a letter and not ending in a hyphen."
  }
}

variable "environment" {
  description = "Environment name. Only 'dev' is supported during the POC."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev"], var.environment)
    error_message = "environment must be 'dev'. Additional environments are deliberately out of scope for the POC."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "swedencentral"

  validation {
    condition     = contains(["swedencentral", "westeurope", "northeurope"], var.location)
    error_message = "location must be one of: swedencentral, westeurope, northeurope."
  }
}

###############################################################################
# Application
###############################################################################

variable "container_image" {
  description = <<-EOT
    Fully qualified container image reference including tag.
    The tag MUST be an immutable 40-character git SHA (or the bootstrap
    placeholder). Mutable tags such as ':latest' are rejected so that the
    deployment repo always records exactly what is running.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.\\-_/:]+:([0-9a-f]{40}|bootstrap)$", var.container_image))
    error_message = "container_image tag must be a 40-char git SHA, or the literal 'bootstrap' for initial provisioning. Mutable tags like ':latest' are not permitted."
  }
}

variable "container_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8000

  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "cpu" {
  description = "vCPU allocated to the container. Must pair with memory per Container Apps allowed combinations."
  type        = number
  default     = 0.25

  validation {
    condition     = contains([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], var.cpu)
    error_message = "cpu must be one of: 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0."
  }
}

variable "memory" {
  description = "Memory allocated to the container, e.g. '0.5Gi'. Container Apps requires memory to be exactly 2x cpu in Gi."
  type        = string
  default     = "0.5Gi"

  validation {
    condition     = contains(["0.5Gi", "1Gi", "1.5Gi", "2Gi", "2.5Gi", "3Gi", "3.5Gi", "4Gi"], var.memory)
    error_message = "memory must be one of: 0.5Gi, 1Gi, 1.5Gi, 2Gi, 2.5Gi, 3Gi, 3.5Gi, 4Gi."
  }
}

variable "min_replicas" {
  description = "Minimum replica count. 0 enables scale-to-zero."
  type        = number
  default     = 0

  validation {
    condition     = var.min_replicas >= 0 && var.min_replicas <= 3
    error_message = "min_replicas must be between 0 and 3 during the POC."
  }
}

variable "max_replicas" {
  description = "Maximum replica count."
  type        = number
  default     = 2

  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 3
    error_message = "max_replicas must be between 1 and 3 during the POC."
  }
}

variable "app_env" {
  description = "Non-secret environment variables passed to the container. Never put credentials here; they belong in Key Vault."
  type        = map(string)
  default     = {}

  validation {
    condition = length([
      for k, v in var.app_env : k
      if can(regex("(?i)(password|secret|token|key|credential|conn)", k))
    ]) == 0
    error_message = "app_env keys must not look like secrets (password/secret/token/key/credential/conn). Secrets are provisioned through Key Vault."
  }
}

###############################################################################
# Database
###############################################################################

variable "postgres_sku" {
  description = <<-EOT
    Postgres Flexible Server SKU.

    Burstable tiers only. General Purpose SKUs are deliberately excluded from
    the allowed set during the POC: GP_Standard_D2s_v3 is roughly 100 USD/month
    and there is no POC workload that justifies it. Widening this list is a
    conscious decision, not something an agent should be able to reach.
  EOT
  type        = string
  default     = "B_Standard_B1ms"

  validation {
    condition     = contains(["B_Standard_B1ms", "B_Standard_B2s"], var.postgres_sku)
    error_message = "postgres_sku must be B_Standard_B1ms or B_Standard_B2s. General Purpose SKUs are out of scope for the POC on cost grounds."
  }
}

variable "postgres_storage_mb" {
  description = <<-EOT
    Postgres storage in MB. Azure only accepts specific values.

    Storage CANNOT be reduced after creation - only grown. An over-sized
    choice is therefore permanent for the life of the server, which is why
    the allowed set stops at 64 GB for the POC.
  EOT
  type        = number
  default     = 32768

  validation {
    condition     = contains([32768, 65536], var.postgres_storage_mb)
    error_message = "postgres_storage_mb must be 32768 (32 GB) or 65536 (64 GB). Larger sizes are out of scope for the POC and cannot be undone."
  }
}

variable "postgres_version" {
  description = "Postgres major version."
  type        = string
  default     = "16"

  validation {
    condition     = contains(["15", "16"], var.postgres_version)
    error_message = "postgres_version must be '15' or '16'."
  }
}

variable "database_name" {
  description = "Application database name."
  type        = string
  default     = "appdb"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{1,30}$", var.database_name))
    error_message = "database_name must be lowercase alphanumeric/underscore, starting with a letter, 2-31 chars."
  }
}

variable "postgres_backup_retention_days" {
  description = "Backup retention in days."
  type        = number
  default     = 7

  validation {
    condition     = var.postgres_backup_retention_days >= 7 && var.postgres_backup_retention_days <= 35
    error_message = "postgres_backup_retention_days must be between 7 and 35."
  }
}

###############################################################################
# Registry (private image pull)
###############################################################################

variable "registry_server" {
  description = "Container registry hostname. Leave as default for GHCR."
  type        = string
  default     = "ghcr.io"
}

variable "registry_username" {
  description = "Registry username. For GHCR this is the GitHub account or org name. Empty means the image is public and no pull credential is configured."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Registry password / PAT with read:packages. Stored as a Container App secret, never in state as plaintext output."
  type        = string
  default     = ""
  sensitive   = true
}

###############################################################################
# Networking
###############################################################################

variable "vnet_address_space" {
  description = "VNet CIDR. Must be large enough for a /23 apps subnet and a /24 database subnet."
  type        = string
  default     = "10.60.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vnet_address_space)) && tonumber(split("/", var.vnet_address_space)[1]) <= 22
    error_message = "vnet_address_space must be valid CIDR of /22 or larger."
  }
}

###############################################################################
# Governance
###############################################################################

variable "tags" {
  description = "Resource tags. 'owner' and 'costCenter' are mandatory - never guess these, ask the requester."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["owner", "costCenter"] : contains(keys(var.tags), k) && trimspace(lookup(var.tags, k, "")) != ""])
    error_message = "tags must include non-empty 'owner' and 'costCenter'."
  }
}
