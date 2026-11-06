<#
.SYNOPSIS
    Provisions the Azure Storage Account used for Terraform remote state.

.DESCRIPTION
    Run this once before your first `terraform init`. It creates:
      - A resource group
      - A storage account (LRS, TLS-only, no public blob access)
      - A blob container named "tfstate"
      - Assigns the current user (or a specified SPN) Storage Blob Data Contributor

    After it completes, copy the printed backend block into backend.tf and run
    `terraform init`.

.PARAMETER SubscriptionId
    Azure subscription ID where state storage will live.

.PARAMETER Location
    Azure region (e.g. "westeurope"). Defaults to "westeurope".

.PARAMETER ResourceGroupName
    Name of the resource group to create. Defaults to "rg-fabricvending-tfstate".

.PARAMETER StorageAccountName
    Storage account name (3–24 lowercase alphanumeric). Must be globally unique.

.PARAMETER ContainerName
    Blob container name. Defaults to "tfstate".

.PARAMETER AssignRoleTo
    Object ID of a user or SPN to grant Storage Blob Data Contributor.
    Defaults to the currently signed-in user.

.EXAMPLE
    .\bootstrap-backend.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -StorageAccountName "stfabricvendingtf001"

.EXAMPLE
    # Assign role to a CI/CD SPN instead of yourself
    .\bootstrap-backend.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -StorageAccountName "stfabricvendingtf001" `
        -AssignRoleTo "00000000-0000-0000-0000-000000000000"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $Location            = "westeurope",
    [string] $ResourceGroupName   = "rg-fabricvending-tfstate",

    [Parameter(Mandatory)]
    [string] $StorageAccountName,

    [string] $ContainerName       = "tfstate",
    [string] $AssignRoleTo        = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 1. Check prerequisites ────────────────────────────────────────────────────
foreach ($cmd in "az") {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Required tool not found: $cmd. Install the Azure CLI first."
    }
}

# ── 2. Set subscription ───────────────────────────────────────────────────────
Write-Host "Setting subscription: $SubscriptionId"
az account set --subscription $SubscriptionId

# ── 3. Create resource group ──────────────────────────────────────────────────
Write-Host "Creating resource group: $ResourceGroupName"
az group create `
    --name     $ResourceGroupName `
    --location $Location `
    --output   none

# ── 4. Create storage account ─────────────────────────────────────────────────
Write-Host "Creating storage account: $StorageAccountName"
az storage account create `
    --name                   $StorageAccountName `
    --resource-group         $ResourceGroupName `
    --location               $Location `
    --sku                    Standard_LRS `
    --kind                   StorageV2 `
    --min-tls-version        TLS1_2 `
    --allow-blob-public-access false `
    --https-only             true `
    --output                 none

# Enable versioning so accidental state overwrites are recoverable
az storage account blob-service-properties update `
    --account-name  $StorageAccountName `
    --resource-group $ResourceGroupName `
    --enable-versioning true `
    --output none

# ── 5. Create blob container ──────────────────────────────────────────────────
Write-Host "Creating blob container: $ContainerName"
az storage container create `
    --name          $ContainerName `
    --account-name  $StorageAccountName `
    --auth-mode     login `
    --output        none

# ── 6. Assign Storage Blob Data Contributor ───────────────────────────────────
$storageId = az storage account show `
    --name           $StorageAccountName `
    --resource-group $ResourceGroupName `
    --query          id `
    --output         tsv

if ([string]::IsNullOrEmpty($AssignRoleTo)) {
    $AssignRoleTo = az ad signed-in-user show --query id --output tsv
    Write-Host "No -AssignRoleTo provided; using signed-in user: $AssignRoleTo"
}

Write-Host "Assigning Storage Blob Data Contributor to: $AssignRoleTo"
az role assignment create `
    --assignee   $AssignRoleTo `
    --role       "Storage Blob Data Contributor" `
    --scope      $storageId `
    --output     none

# ── 7. Print backend block to copy into backend.tf ───────────────────────────
$backendFile = Join-Path (Split-Path $PSScriptRoot -Parent) "backend.generated.tf"
@"
terraform {
  backend "azurerm" {
    resource_group_name  = "$ResourceGroupName"
    storage_account_name = "$StorageAccountName"
    container_name       = "$ContainerName"
    key                  = "fabric-vending.tfstate"
    use_azuread_auth     = true
  }
}
"@ | Set-Content -Path $backendFile -Encoding utf8

Write-Host ""
Write-Host "Bootstrap complete. Wrote $backendFile (gitignored)."
Write-Host "Next:  terraform init -reconfigure"
