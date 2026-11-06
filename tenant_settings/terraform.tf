terraform {
  required_version = ">= 1.12.0"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
    fabric = {
      source  = "microsoft/fabric"
      version = "~> 1.11"
    }
  }
}
