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
# `pwsh -File` passes "a,b" as one string; accept both forms.
$AdminEmail = @($AdminEmail | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    return $out
}

# Every command names the subscription, so the user's default az subscription is left alone.
$sub = @("--subscription", $SubscriptionId)

# 1. Resource provider
$state = Invoke-Az provider show @sub -n Microsoft.Fabric --query registrationState -o tsv
if ($state -ne "Registered") {
    Write-Host "Registering Microsoft.Fabric (was: $state)"
    Invoke-Az provider register @sub -n Microsoft.Fabric --wait | Out-Null
}

# 2. Resource group (an existing group is reused whatever its region; the capacity may live elsewhere)
if ((Invoke-Az group exists @sub --name $ResourceGroupName) -ne "true") {
    Write-Host "Creating resource group: $ResourceGroupName ($Location)"
    Invoke-Az group create @sub --name $ResourceGroupName --location $Location --output none | Out-Null
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

Write-Host "Done. In parameters/environments/<env>.tfvars set:"
if ($Sku -eq "F0") {
    Write-Host "  create_capacity         = true"
    Write-Host "  capacity_sku            = `"F0`"    # Terraform looks the F0 capacity up instead of creating it"
} else {
    Write-Host "  create_capacity         = false   # it exists already; Terraform must not create it"
    Write-Host "  fabric_capacity_name    = `"$CapacityName`""
}
Write-Host "  capacity_name           = `"$CapacityName`"   # the pipeline pauses/resumes it by these three"
Write-Host "  capacity_resource_group = `"$ResourceGroupName`""
Write-Host "  capacity_subscription_id = `"$SubscriptionId`""
Write-Host "Terraform does not manage this capacity's admins: include the pipeline service principal's object id in -AdminEmail"
Write-Host "(re-run this script with it after bootstrap-identity.ps1), or the pipeline cannot assign workspaces to it."
