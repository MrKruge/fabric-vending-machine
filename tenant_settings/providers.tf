# Same identity model as the workspace stack: the service principal (client secret, OIDC or Azure CLI).
# Fabric admin APIs and Microsoft Graph cannot use a managed identity from a pipeline.

locals {
  use_client_secret = var.fabric_spn_client_secret != null
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

provider "fabric" {
  tenant_id                          = var.tenant_id
  client_id                          = var.fabric_spn_client_id
  client_secret                      = local.use_client_secret ? var.fabric_spn_client_secret : null
  use_oidc                           = local.spn_use_oidc
  use_cli                            = var.fabric_spn_client_id == null
  azure_devops_service_connection_id = var.fabric_service_connection_id
  preview                            = true
}
