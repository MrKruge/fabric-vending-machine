variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID. Find it in Azure Portal → Microsoft Entra ID → Overview."
}

variable "fabric_capacity_id" {
  type        = string
  default     = null
  description = "Fabric capacity GUID (not the ARM resource ID) to assign workspaces to. Alternative to fabric_capacity_name."
}

variable "fabric_capacity_name" {
  type        = string
  default     = null
  description = "Display name of an existing Fabric capacity (e.g. one created by scripts/bootstrap-capacity.ps1, which supports F0). Terraform looks up its GUID. Ignored when fabric_capacity_id is set."
}

# ── Optional: capacity creation ───────────────────────────────────────────────

variable "create_capacity" {
  type        = bool
  default     = false
  description = "Set to true to create a new Fabric capacity. When false, fabric_capacity_id must point to an existing capacity."
}

variable "capacity_name" {
  type        = string
  default     = null
  description = "Name for the new Fabric capacity resource. Required when create_capacity = true."
}

variable "capacity_sku" {
  type        = string
  default     = "F2"
  description = "Fabric capacity SKU. F2 and up are created by Terraform when create_capacity = true. F0 is not supported by the azurerm provider: Terraform skips creation and expects scripts/bootstrap-capacity.ps1 to have created a capacity named capacity_name."
  validation {
    condition     = contains(["F0", "F2", "F4", "F8", "F16", "F32", "F64", "F128", "F256", "F512", "F1024", "F2048"], var.capacity_sku)
    error_message = "Must be a valid Fabric SKU (F0, or F2–F2048)."
  }
}

variable "capacity_resource_group" {
  type        = string
  default     = null
  description = "Name of the resource group for the new capacity. Required when create_capacity = true."
}

variable "capacity_location" {
  type        = string
  default     = "West Europe"
  description = "Azure region for the new capacity. Only used when create_capacity = true."
}

variable "capacity_admin_email" {
  type        = string
  default     = null
  description = "Email address of the Fabric capacity administrator. Required when create_capacity = true."
}

variable "capacity_extra_admins" {
  type        = list(string)
  default     = []
  description = "Additional capacity administrators (UPN of a native member, or service principal object ID). Add the pipeline service principal here so it can assign workspaces to the capacity. Guest (#EXT#) UPNs are rejected by Fabric."
}

variable "capacity_auto_pause" {
  type        = bool
  default     = false
  description = "Read by scripts/capacity.sh, not by Terraform. Opt-in: when true the pipeline pauses the capacity after every plan and apply, so it only bills while Terraform works (and is paused for everyone else in between). Default false: the capacity keeps running. A paused capacity is always resumed before a run."
}

variable "capacity_subscription_id" {
  type        = string
  default     = null
  description = "Azure subscription ID where the capacity resource group lives. Required when create_capacity = true (used to configure the azurerm provider)."
}

variable "workspaces" {
  type = map(object({
    display_name           = string
    data_domain            = string
    environment            = string
    git_integration        = optional(bool, false)
    git_provider_type      = optional(string, "AzureDevOps") # AzureDevOps or GitHub
    git_organization_name  = optional(string, null)
    git_project_name       = optional(string, null)
    git_repository_name    = optional(string, null)
    git_branch_name        = optional(string, "main")
    git_directory_name     = optional(string, "/")
    default_storage_format = optional(string, "Large")
    assign_capacity        = optional(bool, true)
  }))
  description = <<-EOT
    Map of all workspace × environment combinations to vend.
    Recommended key convention: <short_name>_<ENV> (e.g. "finance_DEV").
    Only entries whose `environment` matches `workspace_environment_suffix` are deployed.

    Fields:
    - display_name:          Human-readable workspace name (environment suffix appended automatically).
    - data_domain:           Fabric domain this workspace belongs to. The domain is created (first
                             environment) or looked up (later ones) automatically; "" for none.
    - environment:           DEV, UAT, or PROD.
    - git_integration:       Enable Git integration (typically DEV only).
    - git_provider_type:     AzureDevOps or GitHub (default: AzureDevOps).
    - git_organization_name: Git organisation/account name.
    - git_project_name:      Azure DevOps project (leave null for GitHub).
    - git_repository_name:   Repository name.
    - git_branch_name:       Branch to link (default: main).
    - git_directory_name:    Subfolder in the repo (default: /).
    - default_storage_format: Large or Small (default: Large).
    - assign_capacity:        Assign to fabric_capacity_id (default: true). Set false for Pro workspaces.
  EOT
}

variable "domains" {
  type        = list(string)
  description = "Extra Fabric domain names to create (create_domains = true) or look up (false). Every workspace data_domain is included automatically, so this is for domains no workspace uses (yet, or any more: domains are protected from deletion, so keep a domain here when its last workspace goes). Domains are tenant-wide."
  default     = []
}

variable "create_domains" {
  type        = bool
  default     = false
  description = "true in the first environment the pipeline deploys (acc by default) so it creates the Fabric domains; false in every later one, which looks them up by name. Domains are tenant-wide."
}

variable "workspace_environment_suffix" {
  type        = string
  description = "Active environment stage: DEV, UAT, or PROD. Controls which workspace entries are deployed and how names/groups are suffixed."
  validation {
    condition     = contains(["DEV", "UAT", "PROD"], var.workspace_environment_suffix)
    error_message = "Must be DEV, UAT, or PROD."
  }
}

variable "group_prefix" {
  type        = string
  default     = "FABRIC_WORKSPACE"
  description = "Prefix for all vended AAD security groups, e.g. FABRIC_WORKSPACE → FABRIC_WORKSPACE_<NAME>_<ENV>_<ROLE>."
}

variable "owner_group_display_name" {
  type        = string
  default     = null
  description = "Optional. Display name of an existing AAD group to nest into each workspace's Admin group (DEV/UAT) or Member group (PROD). Leave null to skip."
}

variable "workspace_admin_user_object_ids" {
  type        = list(string)
  default     = []
  description = "Optional. Object IDs of users (members or guests) added to the Admin group of every vended workspace, so they administer all of them. Group membership is what grants the workspace Admin role. Leave empty to skip."
}

variable "deployment_spn_object_id" {
  type        = string
  default     = null
  description = "Optional. Object ID of a Service Principal to assign Admin on all vended workspaces (e.g. a CI/CD pipeline SPN). Leave null to skip."
}

variable "git_connection_id" {
  type        = string
  default     = null
  description = "Optional. Fabric configured Git connection ID to use for workspace Git integration. Required when git_integration = true on any workspace."
}

variable "fabric_spn_client_id" {
  type        = string
  default     = null
  description = "Client ID of the Service Principal. Required for SPN auth (client-secret or OIDC). Leave null to use Azure CLI auth."
}

variable "azure_client_id" {
  type        = string
  default     = null
  description = "Client ID of the user-assigned managed identity used by the azurerm provider (capacity creation). Leave null to use fabric_spn_client_id / Azure CLI for azurerm as well."
}

variable "azure_service_connection_id" {
  type        = string
  default     = null
  description = "Azure DevOps service connection ID (GUID) backing azure_client_id. Only set when running in an Azure DevOps pipeline."
}

variable "fabric_service_connection_id" {
  type        = string
  default     = null
  description = "Azure DevOps service connection ID (GUID) backing fabric_spn_client_id. Only set when running in an Azure DevOps pipeline."
}

variable "fabric_spn_client_secret" {
  type        = string
  sensitive   = true
  default     = null
  description = "Client secret for the SPN. Set for local/secret-based auth. Leave null to use OIDC (pipeline) or Azure CLI (local dev). Never commit this value."
}
