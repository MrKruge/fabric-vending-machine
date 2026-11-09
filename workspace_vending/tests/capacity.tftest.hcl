mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "fabric" {}

variables {
  tenant_id                    = "00000000-0000-0000-0000-000000000000"
  workspace_environment_suffix = "DEV"
  workspaces                   = {}
  create_capacity              = true
  capacity_name                = "fabvendingdemo"
  capacity_resource_group      = "rg-test"
  capacity_admin_email         = "admin@example.com"
  capacity_subscription_id     = "00000000-0000-0000-0000-000000000000"
}

run "f0_skips_azurerm_and_looks_up_by_name" {
  command = plan
  variables {
    capacity_sku = "F0"
  }
  assert {
    condition     = length(azurerm_fabric_capacity.this) == 0
    error_message = "F0 must not be created by the azurerm provider."
  }
  assert {
    condition     = length(data.fabric_capacity.this) == 1
    error_message = "F0 capacity must be looked up by name."
  }
}

run "f2_is_created_by_terraform" {
  command = plan
  variables {
    capacity_sku = "F2"
  }
  assert {
    condition     = length(azurerm_fabric_capacity.this) == 1
    error_message = "F2 must be created by azurerm."
  }
}

run "invalid_sku_rejected" {
  command = plan
  variables {
    capacity_sku = "F3"
  }
  expect_failures = [var.capacity_sku]
}
