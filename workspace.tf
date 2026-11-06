# ── Workspaces ────────────────────────────────────────────────────────────────

resource "fabric_workspace" "this" {
  for_each = local.active_workspaces

  display_name = "${each.value.display_name}${local.workspace_name_suffix}"
  capacity_id  = each.value.assign_capacity ? local.effective_capacity_id : null
}

# ── Domain Assignments ────────────────────────────────────────────────────────
# One resource per domain, assigning all workspaces that belong to it.
# Only runs for domains whose ID is known (skipped gracefully if domain doesn't exist yet).

resource "fabric_domain_workspace_assignments" "this" {
  for_each = toset([
    for ws in local.active_workspaces : ws.data_domain
    if contains(keys(local.domain_ids), ws.data_domain)
  ])

  domain_id = local.domain_ids[each.key]

  workspace_ids = [
    for ws_key, ws in local.active_workspaces : fabric_workspace.this[ws_key].id
    if ws.data_domain == each.key
  ]
}

# ── Git Integration ───────────────────────────────────────────────────────────
# Only wired up for workspaces with git_integration = true (typically DEV stage).
# Requires var.git_connection_id to be set.

resource "fabric_workspace_git" "this" {
  for_each = {
    for k, v in local.active_workspaces : k => v
    if v.git_integration == true
  }

  workspace_id            = fabric_workspace.this[each.key].id
  initialization_strategy = "PreferWorkspace"

  git_provider_details = {
    git_provider_type = each.value.git_provider_type
    organization_name = each.value.git_organization_name
    project_name      = each.value.git_project_name
    repository_name   = each.value.git_repository_name
    branch_name       = each.value.git_branch_name
    directory_name    = each.value.git_directory_name
  }

  git_credentials = {
    source        = "ConfiguredConnection"
    connection_id = var.git_connection_id
  }
}

# ── AAD Security Groups ───────────────────────────────────────────────────────
# 4 groups per workspace: Admin, Contributor, Viewer, Member
# Naming: <group_prefix>_<WORKSPACE_NAME>_<ENV>_<ROLE>

resource "azuread_group" "workspace_role" {
  for_each = local.workspace_roles

  display_name     = "${var.group_prefix}_${replace(replace(upper(each.value.display_name), " - ", "_"), " ", "_")}${local.group_env_suffix}_${upper(each.value.role_key)}"
  description      = "Fabric workspace ${lower(each.value.role_key)} access — ${each.value.display_name}"
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]

  lifecycle {
    ignore_changes = [owners]
  }
}

# ── Fabric Workspace Role Assignments ─────────────────────────────────────────

resource "fabric_workspace_role_assignment" "this" {
  for_each = local.workspace_roles

  workspace_id = fabric_workspace.this[each.value.ws_key].id
  principal = {
    id   = azuread_group.workspace_role[each.key].object_id
    type = "Group"
  }
  role = each.value.fabric_role
}

# ── Optional: Owner Group Nesting ─────────────────────────────────────────────
# If owner_group_display_name is set, nest that group into:
#   - Admin AAD group on DEV and UAT
#   - Member AAD group on PROD

resource "azuread_group_member" "owner" {
  for_each = var.owner_group_display_name != null ? local.active_workspaces : {}

  group_object_id  = azuread_group.workspace_role["${each.key}_${var.workspace_environment_suffix == "PROD" ? "Member" : "Admin"}"].object_id
  member_object_id = data.azuread_group.owner[0].object_id
}

# ── Optional: Admin users ─────────────────────────────────────────────────────
# Adds the listed users to the Admin group of every active workspace.

resource "azuread_group_member" "admin_user" {
  for_each = {
    for pair in setproduct(keys(local.active_workspaces), var.workspace_admin_user_object_ids) :
    "${pair[0]}_${pair[1]}" => { ws_key = pair[0], user_id = pair[1] }
  }

  group_object_id  = azuread_group.workspace_role["${each.value.ws_key}_Admin"].object_id
  member_object_id = each.value.user_id
}

# ── Optional: Deployment SPN Admin ───────────────────────────────────────────
# Grants a CI/CD SPN Admin access on every vended workspace.

resource "fabric_workspace_role_assignment" "deployment_spn" {
  for_each = var.deployment_spn_object_id != null ? local.active_workspaces : {}

  workspace_id = fabric_workspace.this[each.key].id
  principal = {
    id   = var.deployment_spn_object_id
    type = "ServicePrincipal"
  }
  role = "Admin"
}
