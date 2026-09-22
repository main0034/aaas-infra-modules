# `app-stack`

A container application backed by a private Postgres Flexible Server.

**This README is the agent-facing contract.** The agent selecting infrastructure reads this file and `aaas-deployments/schemas/app-stack.schema.json`. If they disagree, the schema wins and this file is a bug.

## What it creates

| Resource | Notes |
|---|---|
| Resource group | `rg-<name>-<env>` |
| VNet + 2 subnets | `/23` delegated to Container Apps, `/24` delegated to Postgres |
| Private DNS zone + VNet link | Created before the DB server, deliberately |
| Postgres Flexible Server | Private access only, no public endpoint, TLS required |
| Postgres database | Named by `database_name` |
| User-assigned managed identity | Attached to the container app |
| Log Analytics workspace | 30-day retention |
| Container App Environment | VNet-injected, explicit Consumption workload profile |
| Container App | External HTTPS ingress, `/health` liveness and readiness probes, `migrate` init container |

There is no database credential anywhere: not in git, not in Terraform state, not in a Container App secret. Postgres accepts Entra ID authentication only, the app's user-assigned managed identity is the database administrator, and the app fetches a short-lived token for each connection. The container receives connection *details* only: `PGHOST`, `PGDATABASE`, `PGUSER`, `AZURE_CLIENT_ID`, `PORT`.

## Image contract

`container_image` must be built from `aaas-app-template`, or honour the same contract:

| | |
|---|---|
| Port | Listens on `$PORT` (set from `container_port`) |
| `GET /health` | Returns 200 within seconds of start, **without touching the database**. Both probes use it |
| `migrate` argument | Started with the single argument `migrate`, applies pending schema migrations and exits 0. Exits non-zero on failure. Safe to run concurrently and repeatedly |
| User | Non-root |

The `migrate` argument is new in `v0.3.0`. An image that does not honour it — anything built from the earlier Python template — fails in the init container and never starts. Move the app to the current template before bumping `ref` to `v0.3.0` or later.

### Why not Key Vault

History, kept because it explains the design. An earlier version stored the connection string in Key Vault and resolved it via a Key Vault reference. That was removed after the POC, for three reasons:

1. `azurerm_key_vault_secret` needs a **data-plane read on every refresh**. The plan identity is Reader-only by design, so every plan failed with `ForbiddenByRbac`. Fixing it means letting the plan identity read secrets *while running Terraform against unreviewed PR content* — worse than what Key Vault was providing.
2. It protected nothing. Terraform builds the connection string, so the value is in state regardless. Key Vault was guarding a secret already written to the state blob.
3. It cost a 60-second RBAC propagation sleep, two role assignments, and a vault whose soft-delete complicated teardown.

There was also a subtler problem: the deployer role assignment used `data.azurerm_client_config.current.object_id`, so its `principal_id` differed between the plan and apply identities. Every plan proposed replacing it. **A module whose desired state depends on who is running Terraform is broken**, and that is easy to miss until you have two identities.

For the real product, secrets should be rotatable independently of Terraform — but solve that by taking the value out of Terraform entirely, not by putting Key Vault in front of a value Terraform already knows.

## Inputs

| Name | Type | Default | Allowed values |
|---|---|---|---|
| `name` | string | — | 3–22 chars, `^[a-z][a-z0-9-]*[a-z0-9]$` |
| `environment` | string | `dev` | `dev` |
| `location` | string | `swedencentral` | `swedencentral`, `westeurope`, `northeurope` |
| `container_image` | string | — | Tag must be a 40-char git SHA, or `bootstrap` |
| `container_port` | number | `8000` | 1–65535 |
| `cpu` | number | `0.25` | `0.25`, `0.5`, `0.75`, `1.0`, `1.25`, `1.5`, `1.75`, `2.0` |
| `memory` | string | `0.5Gi` | Must equal exactly `cpu × 2` in Gi |
| `min_replicas` | number | `0` | 0–3 |
| `max_replicas` | number | `2` | 1–3 |
| `app_env` | map(string) | `{}` | Keys must not look like secrets |
| `postgres_sku` | string | `B_Standard_B1ms` | `B_Standard_B1ms`, `B_Standard_B2s` |
| `postgres_storage_mb` | number | `32768` | `32768`, `65536` |
| `postgres_version` | string | `16` | `15`, `16` |
| `database_name` | string | `appdb` | lowercase, `^[a-z][a-z0-9_]*$` |
| `postgres_backup_retention_days` | number | `7` | 7–35 |
| `registry_server` | string | `ghcr.io` | any |
| `registry_username` | string | `""` | empty means public image, no pull credential |
| `registry_password` | string | `""` | sensitive; supply via `TF_VAR_registry_password` |
| `vnet_address_space` | string | `10.60.0.0/16` | `/22` or larger |
| `tags` | map(string) | — | **must** include non-empty `owner` and `costCenter` |

### Sizing guidance for the agent

- Low-traffic internal tool or demo: `cpu = 0.25`, `memory = "0.5Gi"`, `min_replicas = 0`, `postgres_sku = "B_Standard_B1ms"`.
- Small production-ish API: `cpu = 0.5`, `memory = "1Gi"`, `min_replicas = 1`, `postgres_sku = "B_Standard_B2s"`.
- Anything heavier is out of scope for the POC — ask the requester rather than inventing a shape.

`min_replicas = 0` means the app scales to zero and the first request after idle takes several seconds. Choose it for demos and internal tools; avoid it where anyone expects a fast first response.

### What this costs

Roughly **$17–20/month** if left running continuously, almost all of it Postgres compute and storage. The container app itself is effectively free: the Container Apps monthly free grant (180,000 vCPU-seconds) covers about 200 hours at `cpu = 0.25`, and `min_replicas = 0` means no charge at all while idle.

Postgres is billed per hour whether or not anything connects to it, so the effective way to control POC spend is to run `destroy.yml` when you stop for the day, not to shrink the container.

The subscription has a $20/month budget alert configured by `bootstrap.sh`. If it fires, the cause is almost certainly deployments left running rather than any single resource being mis-sized.

## Outputs

`app_url`, `app_fqdn`, `resource_group_name`, `postgres_fqdn`, `database_name`, `app_identity_principal_id`.

## Usage

```hcl
module "app" {
  source = "git::https://github.com/main0034/aaas-infra-modules.git//modules/app-stack?ref=v0.3.0"

  name            = "demo"
  environment     = "dev"
  container_image = "ghcr.io/main0034/aaas-app-demo:bootstrap"

  tags = {
    owner      = "martin"
    costCenter = "poc"
  }
}
```

## Known behaviours worth knowing before you debug something

- **A failed migration shows up as a revision that never becomes ready.** Container Apps documents that in Single revision mode "if an update fails, traffic remains pointed to the old revision". The init container's log (Log Analytics, `ContainerAppConsoleLogs_CL`, container name `migrate`) carries a first line starting `[migrate] FAILED:` that names the cause.
- **A failed migration does not fail the deploy.** Verified 22 September with a migration that only fails against live data: `terraform apply` reported success, the new revision went to `ActivationFailed` holding 100% of the traffic, and the previous revision kept serving every request. Treat a green apply as "Terraform did its job", never as "the application runs" — a deploy needs a post-apply readiness check that forces a replica and asserts `/ready`.
- **The init container's log is not where you would look for it.** `az containerapp logs show --container migrate` answers `Could not find container`. Query Log Analytics instead: `ContainerAppConsoleLogs_CL | where ContainerName_s == "migrate"`. The first line of a failure starts `[migrate] FAILED:`.
- **Scale from zero runs the init container first.** With `min_replicas = 0` every cold start adds one token fetch and one history-table query - about a second - before the app container starts. A database outage therefore also prevents scaling up from zero.
- **The init container needs the managed identity**, which Container Apps only provides to init containers in a workload-profile environment on a Consumption profile. That is what this module creates; do not change the environment type without re-checking this.

- **Postgres delegated subnet is immutable.** It must be empty at creation and cannot be re-delegated. Changing `vnet_address_space` forces a full rebuild of the database.
- **Private DNS ordering.** The zone link is an explicit `depends_on`. If it were missing, the server would sometimes come up resolving the public name and the app would fail to connect with a confusing timeout rather than a clear error.
