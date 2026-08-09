output "app_url" {
  description = "Public HTTPS URL of the container app."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "app_fqdn" {
  description = "Container app ingress FQDN."
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "resource_group_name" {
  description = "Resource group containing the deployment."
  value       = azurerm_resource_group.this.name
}

output "postgres_fqdn" {
  description = "Private FQDN of the Postgres server. Resolvable only from inside the VNet."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  description = "Application database name."
  value       = azurerm_postgresql_flexible_server_database.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI holding the connection string."
  value       = azurerm_key_vault.this.vault_uri
}

output "app_identity_principal_id" {
  description = "Principal ID of the app's user-assigned managed identity."
  value       = azurerm_user_assigned_identity.app.principal_id
}

# Deliberately NOT exposed as an output: the connection string and the admin
# password. They live in Key Vault. Adding them here would write them into
# every plan artifact and PR comment.
