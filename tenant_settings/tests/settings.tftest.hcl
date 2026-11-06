mock_provider "azuread" {}
mock_provider "fabric" {}

variables {
  tenant_id = "00000000-0000-0000-0000-000000000000"
}

run "one_resource_per_setting" {
  command = plan
  variables {
    fabric_tenant_settings = {
      "PublishToWeb" = { enabled = false }
      "ExportToExcel" = {
        enabled      = true
        delegated_to = []
      }
    }
  }
  assert {
    condition     = length(fabric_tenant_setting.this) == 2
    error_message = "Each listed setting must become one fabric_tenant_setting."
  }
}

run "no_delegation_looks_up_no_groups" {
  command = plan
  variables {
    fabric_tenant_settings = {
      "PublishToWeb" = { enabled = false }
    }
  }
  assert {
    condition     = length(data.azuread_group.tenant_setting_group) == 0
    error_message = "A tenant-wide setting must not look up any group."
  }
}

run "shared_group_is_looked_up_once" {
  command = plan
  variables {
    fabric_tenant_settings = {
      "PublishToWeb"  = { enabled = true, delegated_to = ["grp-a"] }
      "ExportToExcel" = { enabled = true, delegated_to = ["grp-a", "grp-b"] }
    }
  }
  assert {
    condition     = length(data.azuread_group.tenant_setting_group) == 2
    error_message = "Each distinct group must be looked up exactly once."
  }
}

run "delegation_and_properties_are_accepted" {
  command = plan
  variables {
    fabric_tenant_settings = {
      "PublishToWeb" = {
        enabled               = true
        delegate_to_capacity  = false
        delegate_to_domain    = false
        delegate_to_workspace = false
        properties = [
          { name = "CreateP2w", type = "Boolean", value = "true" },
        ]
      }
    }
  }
  assert {
    condition     = length(fabric_tenant_setting.this) == 1
    error_message = "A setting with delegation flags and properties must be accepted."
  }
}

run "pipeline_settings_cannot_be_disabled" {
  command = plan
  variables {
    fabric_tenant_settings = {
      "AllowServicePrincipalsUseWriteAdminAPIs" = { enabled = false }
    }
  }
  expect_failures = [var.fabric_tenant_settings]
}
