mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "fabric" {}

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
