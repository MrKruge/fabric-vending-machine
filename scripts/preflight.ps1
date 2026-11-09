<#
.SYNOPSIS
    Read-only checks for the things that most often break a first Fabric Vending run.

.DESCRIPTION
    Changes nothing (the az default subscription is switched for the run, because Entra calls follow it,
    and restored at the end). Run it before the bootstrap scripts. It prints which account and tenant `az` is
    using, then checks:
      - the subscription is visible to that account
      - the chosen SKU is offered in the chosen region
      - Microsoft.Fabric is registered (bootstrap-identity.ps1 registers it if not, so that is a to-do,
        not a failure)
      - the signed-in account can read the directory (a guest, or a role that is not activated in PIM,
        cannot, and the bootstrap scripts will then fail too)
      - the Power BI Service principal exists and is enabled (AADSTS500014 otherwise)
      - every capacity admin resolves to a native member account in the tenant

    Exit code 1 when a check fails.

.EXAMPLE
    pwsh scripts/preflight.ps1 -SubscriptionId <subscription-id> -Sku F2 -Location swedencentral `
        -AdminEmail admin@yourtenant.onmicrosoft.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $SubscriptionId,
    [string]   $Sku       = "F2",
    [Parameter(Mandatory)] [string]   $Location,
    [string[]] $AdminEmail = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$failed = 0
# `pwsh -File` passes "a,b" as one string; accept both forms.
$AdminEmail = @($AdminEmail | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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

# az ad / Graph calls follow the DEFAULT subscription's tenant, whatever --subscription says. Switch the
# default to -SubscriptionId for the run and put the user's own default back however it ends.
$originalSubscription = & az account show --query id -o tsv 2>$null
function Restore-Subscription {
    if ($originalSubscription) { & az account set --subscription $originalSubscription 2>$null | Out-Null }
}
trap { Restore-Subscription; break }
& az account set --subscription $SubscriptionId 2>$null | Out-Null
$sub = @("--subscription", $SubscriptionId)

# Which account and tenant are we talking to? Several signed-in accounts are common, and the
# default one is often not the one for this tenant.
$acct = Try-Az account show @sub --query "{name:name, tenant:tenantId, user:user.name, type:user.type}" -o json
if (-not $acct) {
    Report $false "Subscription $SubscriptionId is not visible to any account signed in to az" `
        "Run 'az account list --all -o table' to see every signed-in account and its subscriptions. Sign in with the account the portal uses ('az login --tenant <tenant-id>'). A subscription created minutes ago can take a while to show up; 'az account clear' then 'az login' refreshes the list."
    Restore-Subscription
    Write-Host ""
    Write-Host "Stopped: the other checks need the subscription."
    exit 1
}
$acct = $acct | ConvertFrom-Json
Write-Host "Signed in as $($acct.user) ($($acct.type)), tenant $($acct.tenant)"
Write-Host "Subscription $($acct.name) ($SubscriptionId)"
Write-Host ""

$regionKey = ($Location -replace "\s", "").ToLower()
$skuJson = Try-Az rest --method get --url "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Fabric/skus?api-version=2023-11-01" `
    --query "value[?name=='$Sku'] | [].{loc:locations[0],restr:length(restrictions)}" -o json
$offered = $false
if ($skuJson) {
    $offered = [bool]($skuJson | ConvertFrom-Json | Where-Object { (($_.loc -replace "\s", "").ToLower() -eq $regionKey) -and $_.restr -eq 0 })
}
Report $offered "SKU $Sku offered in $Location" `
    "List regions: az rest --method get --url 'https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Fabric/skus?api-version=2023-11-01'. F0 is only offered in a few regions, and the region must suit the tenant's geography. If Microsoft.Fabric is not registered yet this list can be empty."

$reg = Try-Az provider show @sub -n Microsoft.Fabric --query registrationState -o tsv
if ($reg -eq "Registered") { Write-Host "[ok]   Microsoft.Fabric registered" }
else { Write-Host "[todo] Microsoft.Fabric not registered (state: $reg). bootstrap-identity.ps1 registers it." }

# Directory read: needed for every Entra lookup here and for the bootstrap scripts.
$canReadDirectory = $null -ne (Try-Az rest --method get --url "https://graph.microsoft.com/v1.0/users?`$top=1&`$select=id" -o tsv --query "value[0].id")
Report $canReadDirectory "Signed-in account can read the directory" `
    "Graph says 'Insufficient privileges'. The account is probably a guest in this tenant, or its admin role is eligible in PIM but not activated. Activate the role (Global Administrator or Privileged Role Administrator for the bootstrap), or sign in with a native admin account of this tenant, then re-run."

if ($canReadDirectory) {
    $pbiRaw = & az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000009-0000-0000-c000-000000000000'&`$select=accountEnabled" -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[skip] Power BI Service principal: could not read it. If Fabric logins fail with AADSTS500014, a Global Administrator must enable it: Entra > Enterprise applications > Power BI Service > Properties."
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
}

$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
foreach ($admin in $AdminEmail) {
    if ($admin -match $guid) {
        Write-Host "[skip] Capacity admin '$admin' is an object id (fine for a service principal)."
        continue
    }
    if (-not $canReadDirectory) {
        Write-Host "[skip] Capacity admin '$admin': the directory cannot be read (see above)."
        continue
    }
    # Look the account up by UPN first, then by mail: some accounts have no mail attribute at all.
    $user = Try-Az rest --method get --url "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($admin))?`$select=userPrincipalName,userType" -o json
    if (-not $user) {
        $filter = [uri]::EscapeDataString("mail eq '$admin' or otherMails/any(m:m eq '$admin')")
        $found = Try-Az rest --method get --url "https://graph.microsoft.com/v1.0/users?`$filter=$filter&`$count=true&`$select=userPrincipalName,userType" `
            --headers "ConsistencyLevel=eventual" --query "value[0]" -o json
        if ($found -and $found -ne "null") { $user = $found }
    }
    if (-not $user -or $user -eq "null") {
        Report $false "Capacity admin '$admin' is not a user in this tenant" `
            "Use the account's user principal name in THIS tenant (az ad user list --query `"[].userPrincipalName`" -o tsv). A personal or other-tenant address is not the same identity."
        continue
    }
    $user = $user | ConvertFrom-Json
    $upn = $user.userPrincipalName
    if ($user.userType -ne "Member") {
        Report $false "Capacity admin '$admin' is a $($user.userType) ($upn)" `
            "Use a native member account of this tenant (name@<tenant>.onmicrosoft.com or a verified domain). Guests are rejected as capacity admins."
    }
    elseif ($upn -match "#EXT#") {
        Report $false "Capacity admin '$admin' is a member, but its UPN '$upn' contains #EXT#" `
            "This happens when a tenant was created with a personal Microsoft account. Fabric rejects '#' in a capacity admin ('Invalid principal name'). Use a native account (name@<tenant>.onmicrosoft.com) as capacity admin, and put both accounts in workspace_admin_user_object_ids."
    }
    else {
        Report $true "Capacity admin '$admin' is a native member ($upn); use this UPN in capacity_admin_email"
    }
}

Restore-Subscription
Write-Host ""
if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host "All checks passed."
