data "azuread_client_config" "current" {}

# Optional: look up an existing owner group to nest into each workspace's Admin/Member group.
data "azuread_group" "owner" {
  count            = var.owner_group_display_name != null ? 1 : 0
  display_name     = var.owner_group_display_name
  security_enabled = true
}
