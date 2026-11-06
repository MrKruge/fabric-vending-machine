# ── Optional: Fabric Capacity ─────────────────────────────────────────────────
# Created by Terraform when create_capacity = true and capacity_sku != "F0".
# F0 is created by scripts/bootstrap-capacity.ps1 (the azurerm provider rejects it);
# Terraform then looks it up by capacity_name. Set create_capacity = false (default)
# to use an existing capacity via fabric_capacity_id or fabric_capacity_name.

resource "azurerm_fabric_capacity" "this" {
  count = var.create_capacity && var.capacity_sku != "F0" ? 1 : 0

  name                = var.capacity_name
  resource_group_name = var.capacity_resource_group
  location            = var.capacity_location

  sku {
    name = var.capacity_sku
    tier = "Fabric"
  }

  administration_members = distinct(concat([var.capacity_admin_email], var.capacity_extra_admins))
}

# The workspace resource needs the Fabric capacity GUID, not the ARM resource ID,
# so always resolve it through the Fabric API by display name.
data "fabric_capacity" "this" {
  count = var.fabric_capacity_id == null && (var.create_capacity || var.fabric_capacity_name != null) ? 1 : 0

  display_name = var.create_capacity ? var.capacity_name : var.fabric_capacity_name

  depends_on = [azurerm_fabric_capacity.this]
}
