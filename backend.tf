# Configure your Terraform state backend here.
# The azurerm backend with OIDC is recommended for CI/CD pipelines.
#
# Example — Azure Blob Storage with OIDC:
#
# terraform {
#   backend "azurerm" {
#     resource_group_name  = "rg-terraform-state"
#     storage_account_name = "yourstorageaccount"
#     container_name       = "tfstate"
#     key                  = "fabric-vending.tfstate"
#     use_oidc             = true
#     use_azuread_auth     = true
#   }
# }
#
# For local development, use the default local backend (no configuration needed).
