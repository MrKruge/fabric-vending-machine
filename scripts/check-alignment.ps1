# check-alignment.ps1
# Validates that Fabric workspaces and their expected AAD security groups exist in
# your tenant, then verifies which groups are actually assigned to each workspace
# and whether those group names match the expected naming convention.
#
# Prerequisites:
#   - Az PowerShell module installed: Install-Module Az
#   - Authenticated: Connect-AzAccount
#   - az CLI available and logged in: az login
#
# Parameters:
#   -GroupPrefix       : AAD group name prefix (default: FABRIC_WORKSPACE)
#   -WorkspaceNames    : Array of workspace display names to check (without env suffix)
#   -Environments      : Array of environments to check per workspace (default: DEV, UAT, PROD)
#
# Usage:
#   .\check-alignment.ps1
#   .\check-alignment.ps1 -GroupPrefix "MY_PREFIX" -WorkspaceNames @("Finance","Sales") -Environments @("DEV","PROD")

param(
    [string]   $GroupPrefix    = "FABRIC_WORKSPACE",
    [string[]] $WorkspaceNames = @(),
    [string[]] $Environments   = @("DEV", "UAT", "PROD")
)

$roles = @("Admin", "Contributor", "Viewer", "Member")

# ── Helper: derive expected AAD group name ────────────────────────────────────
# Mirrors workspace.tf group naming logic.

function Get-GroupName {
    param([string]$DisplayName, [string]$Env, [string]$Role, [string]$Prefix)

    $base      = $DisplayName.ToUpper()
    $base      = $base -replace ' - ', '_'
    $base      = $base -replace ' ', '_'
    $envSuffix = if ($Env -ne "PROD") { "_$Env" } else { "" }

    return "${Prefix}_${base}${envSuffix}_$($Role.ToUpper())"
}

# ── Prompt for workspace names if not provided ────────────────────────────────

if ($WorkspaceNames.Count -eq 0) {
    Write-Host "No workspace names provided. Enter workspace display names (one per line, blank to finish):" -ForegroundColor Yellow
    $WorkspaceNames = @()
    while ($true) {
        $input = Read-Host "  Workspace name"
        if ([string]::IsNullOrWhiteSpace($input)) { break }
        $WorkspaceNames += $input
    }
}

if ($WorkspaceNames.Count -eq 0) {
    Write-Host "No workspaces to check. Exiting." -ForegroundColor Red
    exit 1
}

# Build targets: each workspace checked against each environment
$targets = $WorkspaceNames | ForEach-Object {
    @{ Name = $_; Envs = $Environments }
}

# ── Fetch data ────────────────────────────────────────────────────────────────

Write-Host "Fetching Fabric workspaces..." -ForegroundColor Cyan
$wsResponse      = az rest --method get --url "https://api.fabric.microsoft.com/v1/workspaces" --resource "https://api.fabric.microsoft.com" 2>$null | ConvertFrom-Json
$fabricWorkspaces = $wsResponse.value | Select-Object id, displayName

Write-Host "Fetching AAD groups (${GroupPrefix}_*)..." -ForegroundColor Cyan
$aadGroups = Get-AzADGroup -Filter "startswith(displayName,'${GroupPrefix}_')" |
    Select-Object -ExpandProperty DisplayName

Write-Host ""

# ── SECTION 1: Expected alignment ─────────────────────────────────────────────

$wsMissing = 0; $wsFound = 0; $grpMissing = 0; $grpFound = 0

Write-Host "── SECTION 1: Expected workspaces and AAD groups ─────────────────────────────────────────────────────────────" -ForegroundColor White
Write-Host ""
"{0,-50} {1,-5}  {2,-4}  {3,-60} {4}" -f "Workspace", "Env", "WS", "AAD Group", "Group" | Write-Host -ForegroundColor White
("-" * 130) | Write-Host

foreach ($target in $targets) {
    foreach ($env in $target.Envs) {
        $wsDisplay = if ($env -eq "PROD") { $target.Name } else { "$($target.Name) $env" }

        $wsExists = ($fabricWorkspaces | Where-Object { $_.displayName -eq $wsDisplay }) -ne $null
        $wsMark   = if ($wsExists) { "✓"; $wsFound++ } else { "✗"; $wsMissing++ }

        $firstRow = $true
        foreach ($role in $roles) {
            $groupName = Get-GroupName -DisplayName $target.Name -Env $env -Role $role -Prefix $GroupPrefix

            $grpExists = $aadGroups -contains $groupName
            $grpMark   = if ($grpExists) { "✓"; $grpFound++ } else { "✗"; $grpMissing++ }
            $grpColor  = if ($grpExists) { "Green" } else { "Red" }

            $wsCol  = if ($firstRow) { $target.Name } else { "" }
            $envCol = if ($firstRow) { $env } else { "" }
            $wsM    = if ($firstRow) { $wsMark } else { " " }

            $line = "{0,-50} {1,-5}  {2,-4}  {3,-60}" -f $wsCol, $envCol, $wsM, $groupName
            Write-Host $line -NoNewline
            Write-Host " $grpMark" -ForegroundColor $grpColor

            $firstRow = $false
        }
        Write-Host ""
    }
}

("-" * 130) | Write-Host
Write-Host "Summary" -ForegroundColor White
Write-Host "  Workspaces : " -NoNewline
Write-Host "$wsFound found  " -ForegroundColor Green -NoNewline
Write-Host "$wsMissing missing" -ForegroundColor Red
Write-Host "  AAD Groups : " -NoNewline
Write-Host "$grpFound found  " -ForegroundColor Green -NoNewline
Write-Host "$grpMissing missing" -ForegroundColor Red
Write-Host ""

# ── SECTION 2: Actual workspace role assignments ───────────────────────────────

Write-Host ""
Write-Host "── SECTION 2: Actual role assignments per workspace ──────────────────────────────────────────────────────────" -ForegroundColor White
Write-Host "(Checking what is ACTUALLY assigned in Fabric vs what is EXPECTED)" -ForegroundColor DarkGray
Write-Host ""

$expectedPattern = "^${GroupPrefix}_"

foreach ($target in $targets) {
    foreach ($env in $target.Envs) {
        $wsDisplay = if ($env -eq "PROD") { $target.Name } else { "$($target.Name) $env" }

        $wsObj = $fabricWorkspaces | Where-Object { $_.displayName -eq $wsDisplay }
        if (-not $wsObj) {
            Write-Host "  [$wsDisplay]" -ForegroundColor Red -NoNewline
            Write-Host " — workspace not found in Fabric, skipping" -ForegroundColor DarkGray
            Write-Host ""; continue
        }

        Write-Host "  [$wsDisplay]" -ForegroundColor Cyan
        Write-Host "  Workspace ID: $($wsObj.id)" -ForegroundColor DarkGray

        $raUrl      = "https://api.fabric.microsoft.com/v1/workspaces/$($wsObj.id)/roleAssignments"
        $raResponse = az rest --method get --url $raUrl --resource "https://api.fabric.microsoft.com" 2>$null | ConvertFrom-Json

        if (-not $raResponse -or -not $raResponse.value) {
            Write-Host "  (no role assignments returned or API error)" -ForegroundColor DarkYellow
            Write-Host ""; continue
        }

        $expectedGroups = @{}
        foreach ($role in $roles) {
            $expectedGroups[$role] = Get-GroupName -DisplayName $target.Name -Env $env -Role $role -Prefix $GroupPrefix
        }

        $hasIssue = $false
        foreach ($assignment in $raResponse.value) {
            $principalId   = $assignment.principal.id
            $principalType = $assignment.principal.type
            $fabricRole    = $assignment.role

            if ($principalType -eq "Group") {
                $groupObj    = Get-AzADGroup -ObjectId $principalId -ErrorAction SilentlyContinue
                $displayName = if ($groupObj) { $groupObj.DisplayName } else { "(unknown — id: $principalId)" }
            } elseif ($principalType -eq "ServicePrincipal") {
                $displayName = "(ServicePrincipal — id: $principalId)"
            } elseif ($principalType -eq "User") {
                $displayName = "(User — id: $principalId)"
            } else {
                $displayName = "($principalType — id: $principalId)"
            }

            $matchesConvention  = $displayName -match $expectedPattern
            $isExpectedForThisWs = $expectedGroups.Values -contains $displayName

            if ($principalType -ne "Group") {
                $status = "INFO"; $color = "DarkGray"; $mark = "i"
            } elseif ($isExpectedForThisWs -and $matchesConvention) {
                $status = "OK"; $color = "Green"; $mark = "✓"
            } elseif ($matchesConvention -and -not $isExpectedForThisWs) {
                $status = "WARN — correct naming but wrong workspace"; $color = "Yellow"; $mark = "⚠"; $hasIssue = $true
            } elseif (-not $matchesConvention) {
                $status = "WARN — does not follow ${GroupPrefix}_ naming"; $color = "Red"; $mark = "✗"; $hasIssue = $true
            } else {
                $status = "UNKNOWN"; $color = "DarkYellow"; $mark = "?"
            }

            "{0,-4}  {1,-12}  {2,-60}  {3}" -f $mark, $fabricRole, $displayName, $status | Write-Host -ForegroundColor $color
        }

        if (-not $hasIssue) {
            Write-Host "    All assigned groups match naming convention." -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

Write-Host "── Legend ────────────────────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor White
Write-Host "  ✓  Group assigned and matches the ${GroupPrefix}_* convention for this workspace"
Write-Host "  ⚠  Group follows convention but appears to belong to a different workspace"
Write-Host "  ✗  Group does not follow the ${GroupPrefix}_* naming convention"
Write-Host "  i  Non-group principal (Service Principal, User) — informational only"
Write-Host ""
