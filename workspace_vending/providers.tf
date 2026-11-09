# ── Authentication ─────────────────────────────────────────────────────────────
#
# Three supported modes — pick one per environment:
#
# 1. OIDC / Workload Identity Federation (recommended for CI/CD — no secret)
#    Set in pipeline:
#      ARM_CLIENT_ID, ARM_TENANT_ID, ARM_USE_OIDC=true
#    Leave fabric_spn_client_secret unset (null).
#
# 2. Client secret (local dev / pipelines without OIDC support)
#    Set:  TF_VAR_fabric_spn_client_id, TF_VAR_fabric_spn_client_secret
#    Store the secret in Azure Key Vault or a pipeline secret store — never in YAML.
#
# 3. Azure CLI (local dev only)
#    Run `az login` first. Leave both SPN variables unset.

# Two identities in the pipeline:
#   - azurerm uses a user-assigned managed identity (azure_client_id): everything in Azure.
#   - azuread and fabric use the service principal (fabric_spn_client_id): Fabric APIs and
#     Microsoft Graph cannot use a managed identity from a pipeline.
# When azure_client_id is null, azurerm falls back to the SPN (single-identity setups).

locals {
  use_client_secret = var.fabric_spn_client_secret != null
  azure_client_id   = var.azure_client_id != null ? var.azure_client_id : var.fabric_spn_client_id
  azure_use_secret  = local.use_client_secret && var.azure_client_id == null
  azure_use_oidc    = !local.azure_use_secret && local.azure_client_id != null
  spn_use_oidc      = !local.use_client_secret && var.fabric_spn_client_id != null
}

provider "azuread" {
  tenant_id                          = var.tenant_id
  client_id                          = var.fabric_spn_client_id
  client_secret                      = local.use_client_secret ? var.fabric_spn_client_secret : null
  use_oidc                           = local.spn_use_oidc
  use_cli                            = var.fabric_spn_client_id == null
  ado_pipeline_service_connection_id = var.fabric_service_connection_id
}

# Only used when create_capacity = true; azurerm is not needed otherwise.
provider "azurerm" {
  subscription_id                    = var.capacity_subscription_id
  tenant_id                          = var.tenant_id
  client_id                          = local.azure_client_id
  client_secret                      = local.azure_use_secret ? var.fabric_spn_client_secret : null
  use_oidc                           = local.azure_use_oidc
  use_cli                            = local.azure_client_id == null
  ado_pipeline_service_connection_id = var.azure_service_connection_id
  # The pipeline identity has no subscription-level rights, so it cannot auto-register providers.
  # Microsoft.Fabric is registered by scripts/bootstrap-identity.ps1.
  resource_provider_registrations = "none"
  features {}
}

provider "fabric" {
  tenant_id                          = var.tenant_id
  client_id                          = var.fabric_spn_client_id
  client_secret                      = local.use_client_secret ? var.fabric_spn_client_secret : null
  use_oidc                           = local.spn_use_oidc
  use_cli                            = var.fabric_spn_client_id == null
  azure_devops_service_connection_id = var.fabric_service_connection_id
  preview                            = true
}
