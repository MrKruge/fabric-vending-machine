# Tenant settings are tenant-wide, so this stack has its own state and its own pipeline and is
# independent of the per-environment workspace stack.

locals {
  # Group display names referenced by any setting (enabled or excluded), deduplicated.
  tenant_setting_groups = toset(flatten([
    for s in values(var.fabric_tenant_settings) : concat(s.delegated_to, s.excluded)
  ]))
}

data "azuread_group" "tenant_setting_group" {
  for_each = local.tenant_setting_groups

  display_name     = each.key
  security_enabled = true
}

resource "fabric_tenant_setting" "this" {
  for_each = var.fabric_tenant_settings

  setting_name     = each.key
  enabled          = each.value.enabled
  delete_behaviour = "NoChange"

  delegate_to_capacity  = each.value.delegate_to_capacity
  delegate_to_domain    = each.value.delegate_to_domain
  delegate_to_workspace = each.value.delegate_to_workspace

  enabled_security_groups = length(each.value.delegated_to) > 0 ? [
    for group in each.value.delegated_to : {
      graph_id = data.azuread_group.tenant_setting_group[group].object_id
    }
  ] : null

  excluded_security_groups = length(each.value.excluded) > 0 ? [
    for group in each.value.excluded : {
      graph_id = data.azuread_group.tenant_setting_group[group].object_id
    }
  ] : null

  properties = length(each.value.properties) > 0 ? each.value.properties : null
}
