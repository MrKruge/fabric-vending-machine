<#
.SYNOPSIS
    Creates the Azure Storage Account that holds the Terraform state. Run once, before bootstrap-identity.ps1.

.DESCRIPTION
    Creates, in the given subscription:
      - a resource group
      - a storage account: LRS, TLS 1.2, HTTPS only, no public blob access, no shared key access
        (Entra ID only: the pipelines use use_azuread_auth), blob versioning on
      - a blob container (default "tfstate")
      - Storage Blob Data Contributor for the signed-in user (or -AssignRoleTo), so a person can read
        the state when something needs investigating

    Terraform itself never runs from your machine: the pipelines write their own backend configuration
    from the variables bootstrap-identity.ps1 / bootstrap-github.ps1 set. There is nothing to init here.

    Idempotent. Your default `az` subscription is switched to -SubscriptionId for the run (Entra calls
    follow it) and restored at the end.

.PARAMETER SubscriptionId
    Subscription that will hold the state (usually the same one as the capacities).

.PARAMETER Location
    Azure region, for example "swedencentral". Use the same region as the capacities.

.PARAMETER ResourceGroupName
    Resource group to create. Default "rg-fabricvending-tfstate".

.PARAMETER StorageAccountName
    Storage account name: 3-24 lowercase letters and digits, globally unique.

.PARAMETER ContainerName
    Blob container name. Default "tfstate".

.PARAMETER AssignRoleTo
    Object id of a user or service principal to grant Storage Blob Data Contributor.
    Default: the signed-in user.

.EXAMPLE
    pwsh scripts/bootstrap-backend.ps1 -SubscriptionId <subscription-id> -Location swedencentral `
        -StorageAccountName <globally-unique-name>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $Location,
    [string] $ResourceGroupName = "rg-fabricvending-tfstate",
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string] $StorageAccountName,
    [string] $ContainerName = "tfstate",
    [string] $AssignRoleTo  = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli"
}

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    return $out
}

# az ad / Graph calls follow the DEFAULT subscription's tenant, whatever --subscription says. Switch the
# default to -SubscriptionId for the run and put the user's own default back however it ends.
$originalSubscription = & az account show --query id -o tsv 2>$null
function Restore-Subscription {
    if ($originalSubscription) { & az account set --subscription $originalSubscription 2>$null | Out-Null }
}
trap { Restore-Subscription; break }
& az account set --subscription $SubscriptionId 2>$null | Out-Null
$sub = @("--subscription", $SubscriptionId)
$account = Invoke-Az account show @sub --query "{name:name, tenant:tenantId, user:user.name}" -o json | ConvertFrom-Json
Write-Host "Subscription: $($account.name) ($SubscriptionId), tenant $($account.tenant), signed in as $($account.user)"

Write-Host "Resource group: $ResourceGroupName ($Location)"
Invoke-Az group create @sub --name $ResourceGroupName --location $Location --output none | Out-Null

Write-Host "Storage account: $StorageAccountName"
Invoke-Az storage account create @sub `
    --name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --allow-shared-key-access false `
    --https-only true `
    --output none | Out-Null

# Versioning makes an accidental state overwrite recoverable.
Invoke-Az storage account blob-service-properties update @sub `
    --account-name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --enable-versioning true `
    --output none | Out-Null

# Created through Azure Resource Manager, so it needs neither a key nor a data-plane role.
Write-Host "Blob container: $ContainerName"
Invoke-Az storage container-rm create @sub `
    --storage-account $StorageAccountName `
    --resource-group $ResourceGroupName `
    --name $ContainerName `
    --output none | Out-Null

$storageId = Invoke-Az storage account show @sub --name $StorageAccountName --resource-group $ResourceGroupName --query id -o tsv
if ([string]::IsNullOrEmpty($AssignRoleTo)) {
    $AssignRoleTo = Invoke-Az ad signed-in-user show --query id -o tsv
}
Write-Host "Storage Blob Data Contributor: $AssignRoleTo"
Invoke-Az role assignment create @sub `
    --assignee $AssignRoleTo `
    --role "Storage Blob Data Contributor" `
    --scope $storageId `
    --output none | Out-Null

Restore-Subscription
Write-Host ""
Write-Host "Done. State storage: $ResourceGroupName / $StorageAccountName / $ContainerName"
Write-Host "Next: scripts/bootstrap-identity.ps1 with -StateResourceGroup $ResourceGroupName -StorageAccountName $StorageAccountName -Location $Location"
