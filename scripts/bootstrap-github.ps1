<#
.SYNOPSIS
    Wires an existing Fabric Vending setup (identities from bootstrap-identity.ps1) to GitHub Actions:
    federated credentials for the GitHub OIDC token, repository variables and the GitHub environments
    the workflows use. No secret is created anywhere.

.DESCRIPTION
    Run after bootstrap-backend.ps1 and bootstrap-identity.ps1 (which create the managed identity, the
    service principal and the state storage). Idempotent. Use -DryRun to print what would happen
    without changing anything.

    Needs: `az` signed in to the tenant, `gh` signed in with admin rights on the repository and the
    `workflow` scope (gh auth login -s workflow, or gh auth refresh -s workflow). The repository must
    exist; it may be empty. Pushing the code is safe at any point: the workflows do nothing until
    parameters/environments/<env>.tfvars exist.

    Federated credential subjects. GitHub issues the OIDC subject in one of two shapes. Repositories
    created after 2026-07-15, or opted in, use immutable subjects that embed the owner and repository
    ids (repo:owner@ownerId/repo@repoId:...). The script asks GitHub which prefix the repository uses
    (the OIDC customization endpoint) and builds subjects from it, so it works for both.

    One credential per subject the workflows produce:
      pull requests          <prefix>:pull_request
      pushes to main         <prefix>:ref:refs/heads/main            (plan on push)
      environment acc/prod/global   <prefix>:environment:<name>      (apply jobs)

    GitHub environments: acc, prod, global are created. Pass -ReviewerLogin to require a reviewer on
    prod and global. Required reviewers need a public repository, or GitHub Team/Enterprise for a
    private one; without them prod applies right after acc. The script reads the environments back and
    says which gate is really in place.

    A federated credential with the right name but another subject (left by an earlier onboarding of
    another repository) is replaced. Your default `az` subscription is switched for the run and restored.

.EXAMPLE
    pwsh scripts/bootstrap-github.ps1 -SubscriptionId <sub> -StateResourceGroup rg-fabricvending-tfstate `
        -StorageAccountName <storage> -Repository <owner>/<repo> -ReviewerLogin <your-github-login> -DryRun
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

# az ad / Graph calls follow the DEFAULT subscription's tenant, whatever --subscription says. Switch the
# default to -SubscriptionId for the run and put the user's own default back however it ends.
$originalSubscription = & az account show --query id -o tsv 2>$null
function Restore-Subscription {
    if ($originalSubscription) { & az account set --subscription $originalSubscription 2>$null | Out-Null }
}
trap { Restore-Subscription; break }
& az account set --subscription $SubscriptionId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Subscription $SubscriptionId is not visible to any account signed in to az (az account list --all)." }
# `pwsh -File` passes "dev,acc,prod" as one string; accept both forms.
$Environments = @($Environments | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

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

# ── GitHub access ───────────────────────────────────────────────────────────
Invoke-Gh repo view $Repository --json name | Out-Null
$scopes = (& gh api -i user 2>$null | Select-String -Pattern '^x-oauth-scopes:' | Select-Object -First 1)
if ($scopes -and "$scopes" -notmatch '\bworkflow\b') {
    Write-Host "Note: the gh token lacks the 'workflow' scope, so pushing .github/workflows will be refused. Run: gh auth refresh -h github.com -s workflow"
}

# ── Azure facts ─────────────────────────────────────────────────────────────
$tenantId = Invoke-Az account show --subscription $SubscriptionId --query tenantId -o tsv

$appId = Invoke-Az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) { throw "App registration '$AppName' not found. Run bootstrap-identity.ps1 first." }
$appObjectId = Invoke-Az ad app show --id $appId --query id -o tsv
$miClientId  = Invoke-Az identity list --subscription $SubscriptionId -g $StateResourceGroup --query "[?name=='$IdentityName'].clientId | [0]" -o tsv
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

# Matched on name AND subject: a credential with this name from an earlier onboarding of another
# repository has a different subject and is replaced, otherwise every run fails with AADSTS700213.
function Ensure-Credential {
    param([string] $Kind, [string] $Name, [string] $Subject)
    if ($Kind -eq "app") {
        $existing = Invoke-Az ad app federated-credential list --id $appObjectId --query "[?name=='$Name'] | [0]" -o json | ConvertFrom-Json
        if ($existing -and $existing.subject -eq $Subject -and $existing.issuer -eq $issuer) { Write-Host "  exists (app)      $Name"; return }
        if ($existing) {
            Step "replace credential on app    $Name ($($existing.subject) -> $Subject)"
            if (-not $DryRun) { Invoke-Az ad app federated-credential delete --id $appObjectId --federated-credential-id $existing.id --output none | Out-Null }
        } else { Step "add credential on app        $Name -> $Subject" }
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
        $idArgs = @("--identity-name", $IdentityName, "-g", $StateResourceGroup, "--subscription", $SubscriptionId)
        $existing = Invoke-Az identity federated-credential list @idArgs --query "[?name=='$Name'] | [0]" -o json | ConvertFrom-Json
        if ($existing -and $existing.subject -eq $Subject -and $existing.issuer -eq $issuer) { Write-Host "  exists (identity) $Name"; return }
        if ($existing) {
            Step "replace credential on identity $Name ($($existing.subject) -> $Subject)"
            if (-not $DryRun) { Invoke-Az identity federated-credential delete --name $Name @idArgs --yes --output none | Out-Null }
        } else { Step "add credential on identity   $Name -> $Subject" }
        if ($DryRun) { return }
        Invoke-Az identity federated-credential create --name $Name @idArgs `
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

# Say which gate is really there, not which one was asked for (read-only, also in a dry run).
if ($true) {
    Write-Host ""
    Write-Host "Approval gates (read back from GitHub$(if ($DryRun) { ', current state' })):"
    $ungated = @()
    foreach ($e in @("prod", $GlobalScope)) {
        $rules = & gh api "repos/$Repository/environments/$e" --jq '[.protection_rules[]? | select(.type == "required_reviewers")] | length' 2>$null
        if ($LASTEXITCODE -eq 0 -and [int]$rules -gt 0) { Write-Host "  $e : a reviewer must approve before it applies" }
        else { Write-Host "  $e : NO reviewer, applies without approval"; $ungated += $e }
    }
    if ($ungated) {
        Write-Host "  A push to main applies acc and then prod with nobody approving. Add reviewers (re-run with"
        Write-Host "  -ReviewerLogin), which needs a public repository or GitHub Team/Enterprise, or accept it knowingly."
    }
}
Restore-Subscription
Write-Host ""
Write-Host "Next:"
Write-Host " 1. Push the code to $Repository if it is not there yet (git push <remote> main). That is safe: the"
Write-Host "    workflows skip until parameters/environments/acc.tfvars and prod.tfvars exist."
Write-Host " 2. Commit those tfvars (with capacity_extra_admins set) and your workspace files on a branch and open a"
Write-Host "    pull request. validate and the plan run on it; merging applies."
