# ── Workspace parameter file example ─────────────────────────────────────────
# Copy to parameters/workspaces/<name>.tfvars (files in examples/ are never deployed).
# One file per logical workspace. The pipelines deploy the UAT (acc) and PROD (prod)
# entries; the DEV entry is only deployed once you add a dev environment
# (README: "Adding a DEV environment").
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
