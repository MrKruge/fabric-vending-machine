output "workspace_ids" {
  description = "Map of workspace key → Fabric workspace ID."
  value       = { for k, v in fabric_workspace.this : k => v.id }
}

output "workspace_storage_formats" {
  description = "Map of Fabric workspace ID → default storage format (Large or Small). Only includes capacity-assigned workspaces. Useful for post-apply storage format configuration."
  value       = { for k, v in local.active_workspaces : fabric_workspace.this[k].id => v.default_storage_format if v.assign_capacity }
}

output "domain_ids" {
  description = "Map of domain name → Fabric domain ID."
  value       = local.domain_ids
}

output "aad_group_object_ids" {
  description = "Map of workspace_role key → AAD group object ID."
  value       = { for k, v in azuread_group.workspace_role : k => v.object_id }
}

output "capacity_id" {
  description = "ID of the Fabric capacity (created or supplied). Null if no capacity is used."
  value       = local.effective_capacity_id
}
