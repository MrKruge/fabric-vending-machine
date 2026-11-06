<#
.SYNOPSIS
    Read-only checks for the things that most often break a first Fabric Vending run.

.DESCRIPTION
    Changes nothing. Run before the bootstrap scripts. Checks:
      - Microsoft.Fabric is registered on the subscription
      - the chosen SKU is offered in the chosen region
      - the Power BI Service principal is enabled in the tenant (AADSTS500014 otherwise)
      - every capacity admin is a native member, not a guest (#EXT# UPNs are rejected)

.EXAMPLE
    .\preflight.ps1 -SubscriptionId <sub> -Sku F2 -Location swedencentral `
        -AdminEmail you@yourtenant.onmicrosoft.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $SubscriptionId,
    [string]   $Sku       = "F2",
    [string]   $Location  = "westeurope",
    [string[]] $AdminEmail = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$failed = 0

function Report([bool] $Ok, [string] $Message, [string] $Fix = "") {
    if ($Ok) { Write-Host "[ok]   $Message" }
    else {
        Write-Host "[FAIL] $Message"
        if ($Fix) { Write-Host "       $Fix" }
        $script:failed++
    }
}

function Try-Az {
    $out = & az @args 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

Try-Az account set --subscription $SubscriptionId | Out-Null

$reg = Try-Az provider show -n Microsoft.Fabric --query registrationState -o tsv
Report ($reg -eq "Registered") "Microsoft.Fabric registered (state: $reg)" `
    "az provider register -n Microsoft.Fabric --wait   (bootstrap-capacity.ps1 does this too)"

$regionKey = ($Location -replace "\s", "").ToLower()
$skuJson = Try-Az rest --method get --url "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Fabric/skus?api-version=2023-11-01" `
    --query "value[?name=='$Sku'] | [].{loc:locations[0],restr:length(restrictions)}" -o json
$offered = $false
if ($skuJson) {
    $offered = [bool]($skuJson | ConvertFrom-Json | Where-Object { (($_.loc -replace "\s", "").ToLower() -eq $regionKey) -and $_.restr -eq 0 })
}
Report $offered "SKU $Sku offered in $Location" `
    "List regions: az rest --method get --url 'https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Fabric/skus?api-version=2023-11-01'. F0 is only offered in a few regions, and the region must suit the tenant's geography."

$pbiRaw = & az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000009-0000-0000-c000-000000000000'&`$select=accountEnabled" -o json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[skip] Power BI Service principal: could not read it (the signed-in account lacks a directory role that can read service principals). If Fabric logins fail with AADSTS500014, a Global Administrator must enable it: Entra > Enterprise applications > Power BI Service > Properties."
}
else {
    $pbiList = @(($pbiRaw | ConvertFrom-Json).value)
    if ($pbiList.Count -eq 0) {
        # In a tenant that has never used Fabric or Power BI the service principal does not exist yet.
        Report $false "Power BI Service principal does not exist in this tenant yet" `
            "Sign in once to https://app.fabric.microsoft.com with a tenant account; that creates it. Then re-run this check."
    }
    else {
        Report ([bool]$pbiList[0].accountEnabled) "Power BI Service principal enabled in the tenant" `
            "Entra > Enterprise applications > Power BI Service > Properties > Enabled for users to sign-in = Yes (needs a Global Administrator)"
    }
}

foreach ($admin in $AdminEmail) {
    $type = Try-Az rest --method get --url "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($admin))?`$select=userType" --query userType -o tsv
    if ($type) {
        Report ($type -eq "Member") "Capacity admin '$admin' is a $type" "Use a native Member account."
        if ($type -eq "Member" -and $admin -match "#EXT#") {
            Write-Host "       Note: the UPN contains '#EXT#' but Graph says Member. Capacity admin rejects '#' in some cases; if the capacity create fails with 'Invalid principal name', use the tenant's native UPN (name@tenant.onmicrosoft.com)."
        }
    }
    elseif ($admin -match "#EXT#") {
        Report $false "Capacity admin '$admin' could not be read and looks like a guest UPN" `
            "Use a native Member account, or sign in so Graph can read it."
    }
    else { Write-Host "[skip] Capacity admin '$admin': not a user in this tenant, or not readable (fine for a service principal object ID)." }
}

Write-Host ""
if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host "All checks passed."
