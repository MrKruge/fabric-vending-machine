mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "fabric" {}

override_data {
  target = data.azuread_client_config.current
  values = {
    object_id = "99999999-9999-9999-9999-999999999999"
  }
}

variables {
  tenant_id                    = "00000000-0000-0000-0000-000000000000"
  workspace_environment_suffix = "UAT"
  workspaces = {
    finance_UAT = { display_name = "Finance", data_domain = "Finance", environment = "UAT" }
    sales_UAT   = { display_name = "Sales", data_domain = "Sales", environment = "UAT" }
    sales_PROD  = { display_name = "Sales", data_domain = "Sales", environment = "PROD" }
  }
}

run "admin_users_join_every_active_workspace" {
  command = plan
  variables {
    workspace_admin_user_object_ids = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]
  }
  assert {
    condition     = length(azuread_group_member.admin_user) == 4
    error_message = "2 users x 2 active (UAT) workspaces must give 4 memberships; the PROD workspace is not active."
  }
}

run "no_admin_users_means_no_memberships" {
  command = plan
  assert {
    condition     = length(azuread_group_member.admin_user) == 0
    error_message = "Without admin users no membership must be created."
  }
}
