# ── Workspace parameter file example: POC → PROD, no DEV/UAT stage ──────────
# Use this pattern when a workspace starts as a one-off POC and ships straight
# to production with no separate DEV/UAT environments — common for small
# analytics teams or a single proof-of-concept that "becomes" prod.
#
# Only a single entry is defined (environment = "PROD"). Apply this with
# parameters/environments/prod.tfvars — there is nothing to apply in DEV/UAT
# stages for this workspace, and the module does not require every workspace
# to have all three stages defined.

workspaces = {
  poc_report_PROD = {
    display_name    = "POC Report"
    data_domain     = "Finance" # must already exist or be created by another workspace's DEV stage
    environment     = "PROD"
    git_integration = false # typically skipped for POC-turned-prod workspaces
  }
}
