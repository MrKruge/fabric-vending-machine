# ── Workspace: Sales ─────────────────────────────────────────────────────────

workspaces = {
  sales_DEV = {
    display_name          = "Sales"
    data_domain           = "Sales"
    environment           = "DEV"
    git_integration       = true
    git_provider_type     = "AzureDevOps"
    git_organization_name = "your-org"
    git_project_name      = "Your Project"
    git_repository_name   = "your-repo"
    git_branch_name       = "main"
    git_directory_name    = "/workspaces/Sales"
  }
  sales_UAT = {
    display_name    = "Sales"
    data_domain     = "Sales"
    environment     = "UAT"
    git_integration = false
  }
  sales_PROD = {
    display_name    = "Sales"
    data_domain     = "Sales"
    environment     = "PROD"
    git_integration = false
  }
}
