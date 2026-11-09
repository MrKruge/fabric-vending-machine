# ── Workspace template: POC → PROD, no DEV/UAT stage ─────────────────────────
# Copy to parameters/workspaces/<name>.tfvars (files in examples/ are never deployed).
# Use this when a workspace starts as a one-off POC and goes straight to production.
# Only a PROD entry is defined, so only the prod environment creates it; acc has
# nothing to do for it. Not every workspace needs every stage.

workspaces = {
  poc_report_PROD = {
    display_name    = "POC Report"
    data_domain     = "Finance" # created by the first environment (acc) like every other data_domain
    environment     = "PROD"
    git_integration = false # typically skipped for POC-turned-prod workspaces
  }
}
