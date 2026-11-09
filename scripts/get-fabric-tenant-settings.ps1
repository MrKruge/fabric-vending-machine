<#
.SYNOPSIS
    Retrieves all Fabric tenant settings and outputs them as a table and
    as ready-to-paste Terraform tfvars syntax (fabric_tenant_settings map),
    for use in your own tenant-wide governance IaC alongside this module.

.DESCRIPTION
    Designed to run in Azure Cloud Shell (already authenticated) or locally.
    In Cloud Shell: just run it with -TenantId — no other setup needed.
    Locally with interactive login: run it — a browser prompt will appear.
    Locally with SPN: set FABRIC_CLIENT_ID + FABRIC_CLIENT_SECRET and use -UseSPN.

    Calls GET https://api.fabric.microsoft.com/v1/admin/tenantsettings.
    Requires Fabric tenant admin or Fabric administrator role.

.PARAMETER TenantId
    Azure AD / Entra tenant ID that hosts the Fabric tenant.

.PARAMETER OutputTfvars
    Write the tfvars block to tenant_settings.tfvars.txt in the current directory.

.PARAMETER UseSPN
    Use SPN credentials instead of the Az context.
    Reads FABRIC_CLIENT_ID and FABRIC_CLIENT_SECRET from environment variables.

.PARAMETER UseAzCli
    Use the Azure CLI login (`az login`) instead of the Az PowerShell module. Needs no extra module.
    The signed-in account must be a Fabric administrator.

.PARAMETER CheckPublishToWeb
    After retrieving settings, also query the Power BI Admin API for all reports
    currently published to web (publicly accessible, no authentication required).
    Use this before disabling the PublishToWeb tenant setting to identify what
    would break and needs migrating to a secure sharing method — also a good way
    to surface ClickOps drift: anyone can publish a report to the public internet
    with a single button click, with no record outside this audit.

.EXAMPLE
    # Azure Cloud Shell — already authenticated, just run:
    ./get-fabric-tenant-settings.ps1 -TenantId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    # Also write a tfvars file to the current directory:
    ./get-fabric-tenant-settings.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -OutputTfvars

.EXAMPLE
    # Check which reports are publicly exposed before disabling PublishToWeb:
    ./get-fabric-tenant-settings.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -CheckPublishToWeb

.EXAMPLE
    # SPN login:
    $env:FABRIC_CLIENT_ID     = "..."
    $env:FABRIC_CLIENT_SECRET = "..."
    ./get-fabric-tenant-settings.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -UseSPN -OutputTfvars
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $TenantId,

    [switch] $OutputTfvars,
    [switch] $UseSPN,
    [switch] $UseAzCli,
    [switch] $CheckPublishToWeb
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$FabricScope = "https://api.fabric.microsoft.com/.default"

# ── Acquire token ─────────────────────────────────────────────────────────────

function Get-Token {
    param([string] $TenantId, [string] $Scope, [bool] $UseSPN, [bool] $UseAzCli)

    if ($UseAzCli) {
        $token = & az account get-access-token --resource "https://api.fabric.microsoft.com" --tenant $TenantId --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw "az could not get a Fabric token for tenant $TenantId. Run 'az login --tenant $TenantId' first." }
        return $token
    }

    if ($UseSPN) {
        $ClientId     = $env:FABRIC_CLIENT_ID
        $ClientSecret = $env:FABRIC_CLIENT_SECRET
        if (-not $ClientId -or -not $ClientSecret) {
            throw "UseSPN requires FABRIC_CLIENT_ID and FABRIC_CLIENT_SECRET env vars."
        }

        $Body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $Scope
        }
        $Response = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Method POST `
            -Body $Body `
            -ContentType "application/x-www-form-urlencoded"

        return $Response.access_token
    }
    else {
        # Az context path — works in Cloud Shell (pre-authenticated) and locally.
        # Skips Connect-AzAccount if a context for the target tenant already exists.
        Import-Module Az.Accounts -ErrorAction Stop

        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) {
            Write-Host "  No Az context for tenant $TenantId — launching interactive login ..." -ForegroundColor Cyan
            $null = Connect-AzAccount -TenantId $TenantId -Scope Process -ErrorAction Stop
        }

        $TokenObj = Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com" -TenantId $TenantId -AsSecureString:$false
        # Az.Accounts 3.x+ returns Token as SecureString; 2.x returns plain string. Handle both.
        $RawToken = $TokenObj.Token
        if ($RawToken -is [System.Security.SecureString]) {
            $RawToken = [System.Net.NetworkCredential]::new("", $RawToken).Password
        }
        return $RawToken
    }
}

Write-Host "`nAcquiring token for Fabric tenant $TenantId ..." -ForegroundColor Cyan
$Token = Get-Token -TenantId $TenantId -Scope $FabricScope -UseSPN $UseSPN.IsPresent -UseAzCli $UseAzCli.IsPresent

# ── Call Fabric Admin API ─────────────────────────────────────────────────────

Write-Host "Calling GET /v1/admin/tenantsettings ..." -ForegroundColor Cyan

$Response = Invoke-RestMethod `
    -Uri "https://api.fabric.microsoft.com/v1/admin/tenantsettings" `
    -Method GET `
    -Headers @{ Authorization = "Bearer $Token" }

$Settings = $Response.tenantSettings | Sort-Object tenantSettingGroup, settingName

Write-Host "  → $($Settings.Count) settings returned.`n" -ForegroundColor Green

# ── Table output ──────────────────────────────────────────────────────────────

Write-Host "=== Current Fabric Tenant Settings ===" -ForegroundColor Yellow
$Settings | ForEach-Object {
    $secGroups   = $_.PSObject.Properties['enabledSecurityGroups']?.Value
    $delegateToWS = $_.PSObject.Properties['delegateToWorkspace']?.Value
    $groups = if ($secGroups) { ($secGroups | ForEach-Object { $_.name }) -join ", " } else { "" }

    [PSCustomObject]@{
        Group        = $_.tenantSettingGroup
        SettingName  = $_.settingName
        Enabled      = $_.enabled
        CanScope     = $_.canSpecifySecurityGroups
        ScopedTo     = $groups
        DelegateToWS = $delegateToWS
    }
} | Format-Table -AutoSize

# ── Tfvars output ─────────────────────────────────────────────────────────────

$Lines = [System.Collections.Generic.List[string]]::new()
$Lines.Add("fabric_tenant_settings = {")

$CurrentGroup = $null
foreach ($s in $Settings) {
    # Group header comment
    if ($s.tenantSettingGroup -ne $CurrentGroup) {
        if ($CurrentGroup -ne $null) { $Lines.Add("") }
        $Lines.Add("  # ── $($s.tenantSettingGroup) " + ("-" * [Math]::Max(1, 60 - $s.tenantSettingGroup.Length)))
        $CurrentGroup = $s.tenantSettingGroup
    }

    $enabledStr = ($s.enabled).ToString().ToLower()  # true / false

    # delegated_to: list of group display names if security groups are set
    $secGroups = $s.PSObject.Properties['enabledSecurityGroups']?.Value
    if ($secGroups -and $secGroups.Count -gt 0) {
        $groupList    = ($secGroups | ForEach-Object { "`"$($_.name)`"" }) -join ", "
        $delegatedStr = "[$groupList]"
    } else {
        $delegatedStr = "[]"
    }

    $Lines.Add("  `"$($s.settingName)`" = {")
    $Lines.Add("    enabled      = $enabledStr")
    $Lines.Add("    delegated_to = $delegatedStr")

    $excluded = $s.PSObject.Properties['excludedSecurityGroups']?.Value
    if ($excluded -and $excluded.Count -gt 0) {
        $Lines.Add("    excluded     = [" + (($excluded | ForEach-Object { "`"$($_.name)`"" }) -join ", ") + "]")
    }

    foreach ($kind in "Capacity", "Domain", "Workspace") {
        $flag = $s.PSObject.Properties["delegateTo$kind"]?.Value
        if ($null -ne $flag) { $Lines.Add("    delegate_to_$($kind.ToLower()) = $($flag.ToString().ToLower())") }
    }

    # Empty values are left out: the API rejects an empty Integer and the provider cannot round-trip an empty string.
    # Most settings have no 'properties' key at all. Piping $null into Where-Object still runs the
    # predicate once with $_ = $null, which throws under StrictMode, so skip the absent case first.
    $rawProps = $s.PSObject.Properties['properties']?.Value
    $props = @(if ($null -ne $rawProps) { $rawProps | Where-Object { $null -ne $_ -and [string]$_.value -ne '' } })
    if ($props -and $props.Count -gt 0) {
        $Lines.Add("    properties = [")
        foreach ($p in $props) {
            # Escape for an HCL string: backslash, quote, newline, and ${ / %{ template starts.
            $v = ([string]$p.value).Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n').Replace('${', '$${').Replace('%{', '%%{')
            # The API says "Freetext"; the Terraform provider only accepts "FreeText".
            $t = switch -Regex ([string]$p.type) { '^freetext$' { 'FreeText' } '^mailenabledsecuritygroup$' { 'MailEnabledSecurityGroup' } default { [string]$p.type } }
            $Lines.Add("      { name = `"$($p.name)`", type = `"$t`", value = `"$v`" },")
        }
        $Lines.Add("    ]")
    }

    $Lines.Add("  }")
}

$Lines.Add("}")

$TfvarsBlock = $Lines -join "`n"

Write-Host "`n=== Terraform fabric_tenant_settings block ===" -ForegroundColor Yellow
Write-Host $TfvarsBlock

if ($OutputTfvars) {
    $OutPath = Join-Path $PWD "tenant_settings.tfvars.txt"
    $TfvarsBlock | Set-Content -Path $OutPath -Encoding UTF8
    Write-Host "`nWrote tfvars block to: $OutPath" -ForegroundColor Green
}

# ── Publish-to-web audit ───────────────────────────────────────────────────────

if ($CheckPublishToWeb) {
    Write-Host "`nChecking for reports published to web ..." -ForegroundColor Cyan

    # api.powerbi.com requires a different token audience than api.fabric.microsoft.com.
    # Cloud Shell MSI is the most reliable source — bypasses Az module SecureString issues.
    if ($UseSPN) {
        $PbiToken = $Token  # SPN .default scope covers both APIs
    } elseif ($UseAzCli) {
        $PbiToken = & az account get-access-token --resource "https://analysis.windows.net/powerbi/api" --tenant $TenantId --query accessToken -o tsv
    } else {
        try {
            $PbiToken = (Invoke-RestMethod `
                -Uri "http://localhost:50342/oauth2/token" `
                -Method GET `
                -Headers @{ Metadata = "true" } `
                -Body @{ resource = "https://analysis.windows.net/powerbi/api" }).access_token
        } catch {
            # Fallback for non-Cloud Shell environments
            $PbiTokenObj = Get-AzAccessToken -ResourceUrl "https://analysis.windows.net/powerbi/api" -TenantId $TenantId -AsSecureString:$false
            $PbiToken = if ($PbiTokenObj.Token -is [System.Security.SecureString]) {
                [System.Net.NetworkCredential]::new("", $PbiTokenObj.Token).Password
            } else { $PbiTokenObj.Token }
        }
    }

    $Published = Invoke-RestMethod `
        -Uri "https://api.powerbi.com/v1.0/myorg/admin/widelySharedArtifacts/publishedToWeb" `
        -Method GET `
        -Headers @{ Authorization = "Bearer $PbiToken" }

    # The API returns different shapes depending on whether results exist.
    # Normalise: find the first array-valued property, or treat as empty.
    $artifacts = $null
    foreach ($prop in $Published.PSObject.Properties) {
        if ($prop.Value -is [System.Array] -or $prop.Value -is [System.Collections.IEnumerable]) {
            $artifacts = $prop.Value
            break
        }
    }

    if (-not $artifacts -or @($artifacts).Count -eq 0) {
        Write-Host "  No reports are currently published to web." -ForegroundColor Green
    } else {
        Write-Host "`n  WARNING: $(@($artifacts).Count) report(s) have active public links.`n" -ForegroundColor Red
        Write-Host "  These must be migrated to a secure sharing method before the" -ForegroundColor Yellow
        Write-Host "  PublishToWeb tenant setting is disabled in Terraform.`n" -ForegroundColor Yellow

        $artifacts | ForEach-Object {
            [PSCustomObject]@{
                ReportName    = $_.PSObject.Properties['reportName']?.Value
                WorkspaceName = $_.PSObject.Properties['workspaceName']?.Value
                PublishedBy   = $_.PSObject.Properties['publishedBy']?.Value
                CreatedDate   = $_.PSObject.Properties['createdDateTime']?.Value
                ReportId      = $_.PSObject.Properties['reportId']?.Value
                WorkspaceId   = $_.PSObject.Properties['groupId']?.Value
            }
        } | Format-Table -AutoSize
    }
}
