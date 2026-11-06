locals {
  # Fabric roles vended per workspace
  fabric_roles = {
    Admin       = "Admin"
    Contributor = "Contributor"
    Viewer      = "Viewer"
    Member      = "Member"
  }

  # Filter to only entries for the active environment stage
  active_workspaces = {
    for k, v in var.workspaces : k => v
    if v.environment == var.workspace_environment_suffix
  }

  # PROD groups omit the environment suffix; non-PROD append it (e.g. _DEV)
  group_env_suffix = var.workspace_environment_suffix == "PROD" ? "" : "_${var.workspace_environment_suffix}"

  # PROD workspaces keep the display name as-is; non-PROD append the stage (e.g. "My Workspace DEV")
  workspace_name_suffix = var.workspace_environment_suffix == "PROD" ? "" : " ${var.workspace_environment_suffix}"

  # Flatten: one entry per active workspace × role
  workspace_roles = {
    for pair in flatten([
      for ws_key, ws in local.active_workspaces : [
        for role_key, fabric_role in local.fabric_roles : {
          key          = "${ws_key}_${role_key}"
          ws_key       = ws_key
          display_name = ws.display_name
          role_key     = role_key
          fabric_role  = fabric_role
        }
      ]
    ]) : pair.key => pair
  }

  # Fabric capacity GUID: explicit ID, else looked up by name (created by Terraform or by the bootstrap script).
  effective_capacity_id = var.fabric_capacity_id != null ? var.fabric_capacity_id : try(data.fabric_capacity.this[0].id, null)
}
