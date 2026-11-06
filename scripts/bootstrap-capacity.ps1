<#
.SYNOPSIS
    Registers Microsoft.Fabric and creates (or updates) a Fabric capacity via ARM, then optionally pauses it.

.DESCRIPTION
    Use this instead of Terraform's create_capacity when you need a SKU the azurerm provider
    does not accept yet (e.g. F0, only offered in some regions). Idempotent: safe to re-run.
    Terraform then picks the capacity up by name via -var fabric_capacity_name=<name>.

.PARAMETER SubscriptionId
    Subscription that will hold the capacity.

.PARAMETER CapacityName
    Capacity resource name (lowercase letters/digits, 3-63 chars).

.PARAMETER Sku
    Fabric SKU, e.g. F0, F2. Check availability: az rest --url
    "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Fabric/skus?api-version=2023-11-01"

.PARAMETER Location
    Azure region offering the SKU.

.PARAMETER AdminEmail
    One or more capacity admins (UPN or SPN object ID).

.PARAMETER LeaveRunning
    Skip the final pause. By default the capacity is paused so it does not bill while idle.

.EXAMPLE
    .\bootstrap-capacity.ps1 -SubscriptionId <sub> -CapacityName fabvendingdemo `
        -Sku F0 -Location westcentralus -AdminEmail you@example.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $SubscriptionId,
    [Parameter(Mandatory)] [string]   $CapacityName,
    [Parameter(Mandatory)] [string[]] $AdminEmail,
    [string] $Sku               = "F2",
    [string] $Location          = "westeurope",
    [string] $ResourceGroupName = "rg-fabricvending-capacity",
    [switch] $LeaveRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$apiVersion = "2023-11-01"

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    return $out
}

Invoke-Az account set --subscription $SubscriptionId | Out-Null

# 1. Resource provider
$state = Invoke-Az provider show -n Microsoft.Fabric --query registrationState -o tsv
if ($state -ne "Registered") {
    Write-Host "Registering Microsoft.Fabric (was: $state)"
    Invoke-Az provider register -n Microsoft.Fabric --wait | Out-Null
}

# 2. Resource group (an existing group is reused whatever its region; the capacity may live elsewhere)
if ((Invoke-Az group exists --name $ResourceGroupName) -ne "true") {
    Write-Host "Creating resource group: $ResourceGroupName ($Location)"
    Invoke-Az group create --name $ResourceGroupName --location $Location --output none | Out-Null
}
else { Write-Host "Using existing resource group: $ResourceGroupName" }

# 3. Capacity (PUT is create-or-update)
$body = @{
    location   = $Location
    sku        = @{ name = $Sku; tier = "Fabric" }
    properties = @{ administration = @{ members = $AdminEmail } }
} | ConvertTo-Json -Depth 5 -Compress

$bodyFile = New-TemporaryFile
try {
    Set-Content -Path $bodyFile -Value $body -Encoding utf8
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/${CapacityName}?api-version=$apiVersion"
    Write-Host "Creating/updating capacity $CapacityName ($Sku, $Location)"
    Invoke-Az rest --method put --url $url --body "@$bodyFile" --output none | Out-Null
}
finally { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }

# 4. Wait for provisioning, then pause
do {
    Start-Sleep -Seconds 10
    $props = Invoke-Az rest --method get --url $url --query "properties.[provisioningState,state]" -o tsv
    $prov, $cap = $props -split "\s+"
    Write-Host "  provisioningState=$prov state=$cap"
} while ($prov -notin "Succeeded", "Failed")
if ($prov -eq "Failed") { throw "Capacity provisioning failed" }

if (-not $LeaveRunning -and $cap -eq "Active") {
    Write-Host "Pausing capacity (billing stops; resume with: az rest --method post --url '$($url -replace '\?', '/resume?')')"
    Invoke-Az rest --method post --url ($url -replace '\?', '/suspend?') --output none | Out-Null
}

Write-Host "Done. Use in Terraform:  fabric_capacity_name = `"$CapacityName`""
