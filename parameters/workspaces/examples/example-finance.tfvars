# ── Workspace parameter file example ─────────────────────────────────────────
# One file per logical workspace. Each file defines DEV, UAT, and PROD entries.
# Merge all workspace files together when running terraform plan/apply.
#
# Key convention: <short_name>_<ENV>
# All three environments share the same display_name — the stage suffix is
# appended automatically by the module (e.g. "Finance DEV", "Finance UAT", "Finance").

workspaces = {
  finance_DEV = {
    display_name          = "Finance"
    data_domain           = "Finance"
    environment           = "DEV"
    git_integration       = true
    git_provider_type     = "AzureDevOps"
    git_organization_name = "your-org"
    git_project_name      = "Your Project"
    git_repository_name   = "your-repo"
    git_branch_name       = "main"
    git_directory_name    = "/workspaces/Finance"
  }
  finance_UAT = {
    display_name    = "Finance"
    data_domain     = "Finance"
    environment     = "UAT"
    git_integration = false
  }
  finance_PROD = {
    display_name    = "Finance"
    data_domain     = "Finance"
    environment     = "PROD"
    git_integration = false
  }
}
