variable "tenant_id" {
  type        = string
  description = "Entra tenant ID that hosts the Fabric tenant."
}

variable "fabric_spn_client_id" {
  type        = string
  default     = null
  description = "Client ID of the service principal. Leave null to use Azure CLI auth (local dev)."
}

variable "fabric_service_connection_id" {
  type        = string
  default     = null
  description = "Azure DevOps service connection ID backing fabric_spn_client_id. Only set in an Azure DevOps pipeline."
}

variable "fabric_spn_client_secret" {
  type        = string
  sensitive   = true
  default     = null
  description = "Client secret for the SPN. Leave null to use OIDC (pipeline) or Azure CLI (local dev). Never commit this value."
}

variable "fabric_tenant_settings" {
  type = map(object({
    enabled               = bool
    delegated_to          = optional(list(string), [])
    excluded              = optional(list(string), [])
    delegate_to_capacity  = optional(bool)
    delegate_to_domain    = optional(bool)
    delegate_to_workspace = optional(bool)
    properties = optional(list(object({
      name  = string
      type  = string
      value = string
    })), [])
  }))
  default     = {}
  description = <<-EOT
    Fabric tenant settings to manage. Key is the Fabric API setting name.
    - enabled:      true or false.
    - delegated_to: Entra security group display names the setting is scoped to.
                    Empty means the whole tenant.
    - excluded:     Entra security group display names the setting is switched off for.
    - delegate_to_capacity / _domain / _workspace: whether capacity, domain or workspace admins
                    may override the setting. Leave unset to keep the current value.
    - properties:   extra values some settings carry (retention periods, URLs, mail groups).
                    A setting with properties must list them all, or they are reset.
    Settings not listed here are left untouched. Removing an entry stops managing it; it does not reset it.
    Generate the current values with scripts/get-fabric-tenant-settings.ps1.
  EOT

  # The pipeline's own service principal depends on these. Turning one off would lock it out of
  # the Fabric API, so the plan refuses it.
  validation {
    condition = alltrue([
      for name in [
        "AllowServicePrincipalsUseReadAdminAPIs",
        "AllowServicePrincipalsUseWriteAdminAPIs",
        "ServicePrincipalAccessGlobalAPIs",
      ] : !contains(keys(var.fabric_tenant_settings), name) || var.fabric_tenant_settings[name].enabled
    ])
    error_message = "AllowServicePrincipalsUseReadAdminAPIs, AllowServicePrincipalsUseWriteAdminAPIs and ServicePrincipalAccessGlobalAPIs must stay enabled: the pipeline's service principal needs them."
  }
}
