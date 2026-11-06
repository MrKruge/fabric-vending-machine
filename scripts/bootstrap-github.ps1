<#
.SYNOPSIS
    Wires an existing Fabric Vending setup (identities from bootstrap-identity.ps1) to GitHub Actions:
    federated credentials for the GitHub OIDC token, repository variables and the GitHub environments
    the workflows use. No secret is created anywhere.

.DESCRIPTION
    Run after bootstrap-backend.ps1 and bootstrap-identity.ps1 (which create the managed identity, the
    service principal and the state storage). Idempotent. Use -DryRun to print what would happen
    without changing anything.

    Needs: `az` logged in to the tenant, `gh` logged in with admin rights on the repository.

    Federated credential subjects. GitHub issues the OIDC subject in one of two shapes. Repositories
    created after 2026-07-15, or opted in, use immutable subjects that embed the owner and repository
    ids (repo:owner@ownerId/repo@repoId:...). The script asks GitHub which prefix the repository uses
    (the OIDC customization endpoint) and builds subjects from it, so it works for both.

    One credential per subject the workflows produce:
      pull requests          <prefix>:pull_request
      pushes to main         <prefix>:ref:refs/heads/main            (plan on push)
      environment acc/prod/global   <prefix>:environment:<name>      (apply jobs)

    GitHub environments: acc, prod, global are created. Required reviewers need GitHub Team/Enterprise
    for a private repository (or a public repository); pass -ReviewerLogin to set one where allowed.

.EXAMPLE
    .\bootstrap-github.ps1 -SubscriptionId <sub> -StateResourceGroup rg-fabricvending-tfstate `
        -StorageAccountName <storage> -Repository MyOrg/fabric-vending -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $StateResourceGroup,
    [Parameter(Mandatory)] [string] $StorageAccountName,
    [Parameter(Mandatory)] [string] $Repository,   # owner/name
    [string] $AppName            = "sp-fabricvending-fabric",
    [string] $IdentityName       = "id-fabricvending-pipeline",
    [string[]] $Environments     = @("acc", "prod"),
    [string] $ContainerName      = "tfstate",
    [string] $ReviewerLogin      = "",             # GitHub login added as required reviewer on prod and global
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GlobalScope = "global"
$issuer      = "https://token.actions.githubusercontent.com"

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    return $out
}
function Invoke-Gh {
    $out = & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed" }
    return $out
}
function Step([string] $Text) { Write-Host ($(if ($DryRun) { "[dry-run] " } else { "" }) + $Text) }

if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw "-Repository must be owner/name, got '$Repository'" }

# ── Azure facts ─────────────────────────────────────────────────────────────
Invoke-Az account set --subscription $SubscriptionId | Out-Null
$tenantId = Invoke-Az account show --query tenantId -o tsv

$appId = Invoke-Az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) { throw "App registration '$AppName' not found. Run bootstrap-identity.ps1 first." }
$appObjectId = Invoke-Az ad app show --id $appId --query id -o tsv
$miClientId  = Invoke-Az identity list -g $StateResourceGroup --query "[?name=='$IdentityName'].clientId | [0]" -o tsv
if (-not $miClientId) { throw "Managed identity '$IdentityName' not found in $StateResourceGroup. Run bootstrap-identity.ps1 first." }

# ── Which OIDC subject shape does this repository use? ──────────────────────
$custom = Invoke-Gh api "repos/$Repository/actions/oidc/customization/sub" | ConvertFrom-Json
# Immutable subjects embed the owner and repository ids; GitHub reports the prefix to use. It can be
# reported while use_default is also true, so the immutable flag wins over the default.
$immutable = $custom.PSObject.Properties["use_immutable_subject"] -and $custom.use_immutable_subject
$reported  = if ($custom.PSObject.Properties["sub_claim_prefix"]) { [string]$custom.sub_claim_prefix } else { "" }
if ($immutable -or -not $custom.use_default) {
    if (-not $reported) { throw "Repository uses a non-default OIDC subject but GitHub reported no prefix; set the credentials by hand." }
    $prefix = $reported
} else {
    $prefix = "repo:$Repository"
}
Write-Host "OIDC subject prefix: $prefix"

$subjects = [ordered]@{
    "gh-pull-request"      = "${prefix}:pull_request"
    "gh-main"              = "${prefix}:ref:refs/heads/main"
}
foreach ($e in (@($Environments) + $GlobalScope)) { $subjects["gh-env-$e"] = "${prefix}:environment:$e" }

function Ensure-Credential {
    param([string] $Kind, [string] $Name, [string] $Subject)
    if ($Kind -eq "app") {
        $have = @(Invoke-Az ad app federated-credential list --id $appObjectId --query "[].name" -o tsv)
        if ($have -contains $Name) { Write-Host "  exists (app)      $Name"; return }
        Step "add credential on app        $Name -> $Subject"
        if ($DryRun) { return }
        $file = New-TemporaryFile
        try {
            @{ name = $Name; issuer = $issuer; subject = $Subject; audiences = @("api://AzureADTokenExchange") } |
                ConvertTo-Json | Set-Content -Path $file -Encoding utf8
            Invoke-Az ad app federated-credential create --id $appObjectId --parameters "@$file" --output none | Out-Null
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
    else {
        $have = @(Invoke-Az identity federated-credential list --identity-name $IdentityName -g $StateResourceGroup --query "[].name" -o tsv)
        if ($have -contains $Name) { Write-Host "  exists (identity) $Name"; return }
        Step "add credential on identity   $Name -> $Subject"
        if ($DryRun) { return }
        Invoke-Az identity federated-credential create --name $Name --identity-name $IdentityName -g $StateResourceGroup `
            --issuer $issuer --subject $Subject --audiences "api://AzureADTokenExchange" --output none | Out-Null
    }
}

Write-Host ""
Write-Host "== Federated credentials =="
foreach ($key in $subjects.Keys) {
    Ensure-Credential -Kind identity -Name $key -Subject $subjects[$key]
    Ensure-Credential -Kind app      -Name $key -Subject $subjects[$key]
}

# ── Repository variables (identifiers only, never secrets) ──────────────────
Write-Host ""
Write-Host "== Repository variables =="
$vars = [ordered]@{
    AZURE_TENANT_ID         = $tenantId
    AZURE_SUBSCRIPTION_ID   = $SubscriptionId
    AZURE_CLIENT_ID         = $miClientId
    FABRIC_CLIENT_ID        = $appId
    TFSTATE_RESOURCE_GROUP  = $StateResourceGroup
    TFSTATE_STORAGE_ACCOUNT = $StorageAccountName
    TFSTATE_CONTAINER       = $ContainerName
}
foreach ($k in $vars.Keys) {
    Step "set variable $k"
    if (-not $DryRun) { Invoke-Gh variable set $k --body $vars[$k] --repo $Repository | Out-Null }
}

# ── GitHub environments ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "== GitHub environments =="
$reviewerId = $null
if ($ReviewerLogin) { $reviewerId = [int](Invoke-Gh api "users/$ReviewerLogin" --jq .id) }
foreach ($e in (@($Environments) + $GlobalScope)) {
    $protect = ($e -eq "prod" -or $e -eq $GlobalScope) -and $reviewerId
    Step "create environment $e$(if ($protect) { ' with required reviewer ' + $ReviewerLogin })"
    if ($DryRun) { continue }
    if ($protect) {
        $body = @{ reviewers = @(@{ type = "User"; id = $reviewerId }); prevent_self_review = $false } | ConvertTo-Json -Depth 5
        $body | & gh api --method PUT "repos/$Repository/environments/$e" --input - | Out-Null
    } else {
        & gh api --method PUT "repos/$Repository/environments/$e" | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "  could not create/protect environment $e (required reviewers need GitHub Team/Enterprise on a private repository)" }
}

Write-Host ""
Write-Host "Done$(if ($DryRun) { ' (dry run: nothing was changed)' })."
Write-Host "Remaining manual steps:"
Write-Host " - Run scripts/bootstrap-identity.ps1 first if you have not (it creates the identities and the Entra/Fabric permissions)."
if (-not $ReviewerLogin) {
    Write-Host " - Add required reviewers to the 'prod' and 'global' GitHub environments (or pass -ReviewerLogin)."
}
Write-Host " - Push to main to run the first plan; nothing applies until the environments' reviewers approve."
