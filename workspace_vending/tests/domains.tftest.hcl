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
  workspace_environment_suffix = "PROD"
  workspaces                   = {}
  create_domains               = false
  domains                      = ["Finance", "Sales"]
}

# The mocked domains lookup returns nothing, as prod sees it before acc has created the domains.
run "missing_domains_are_skipped" {
  command = plan
  assert {
    condition     = length(local.domain_ids) == 0
    error_message = "Domains that do not exist yet must be skipped, not fail the plan."
  }
}

# A workspace's data_domain is enough: nobody has to repeat it in var.domains.
run "domains_come_from_workspaces" {
  command = plan
  variables {
    workspace_environment_suffix = "UAT"
    create_domains               = true
    domains                      = []
    workspaces = {
      demo_UAT  = { display_name = "Demo", data_domain = "Demo", environment = "UAT" }
      demo_PROD = { display_name = "Demo", data_domain = "Demo", environment = "PROD" }
      misc_UAT  = { display_name = "Misc", data_domain = "", environment = "UAT" }
    }
  }
  assert {
    condition     = keys(fabric_domain.this) == ["Demo"]
    error_message = "The first environment must create every workspace data_domain, and nothing for an empty one."
  }
}

run "extra_domains_are_kept" {
  command = plan
  variables {
    workspace_environment_suffix = "UAT"
    create_domains               = true
    domains                      = ["Finance"]
    workspaces = {
      demo_UAT = { display_name = "Demo", data_domain = "Demo", environment = "UAT" }
    }
  }
  assert {
    condition     = toset(keys(fabric_domain.this)) == toset(["Demo", "Finance"])
    error_message = "var.domains adds domains on top of the workspace ones."
  }
}
