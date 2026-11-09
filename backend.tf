# No backend is configured here on purpose. Terraform only runs in the pipelines, and they write
# backend.generated.tf (gitignored) at run time from the state storage that
# scripts/bootstrap-backend.ps1 created:
#
#   Azure DevOps:   .azuredevops/steps/terraform.yml   (variable group fabricvending-<env>)
#   GitHub Actions: .github/actions/terraform/action.yml (repository variables TFSTATE_*)
#
# One state file per environment: fabric-vending-<env>.tfstate, authenticated with Entra ID (OIDC).
# Locally only `terraform init -backend=false`, `validate` and `test` are used.
