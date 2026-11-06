<#
.SYNOPSIS
    Prepares Azure and Azure DevOps so the pipeline can take over: a user-assigned managed identity
    for Azure, a service principal for Fabric/Entra, and per environment (default acc, prod) two
    workload-identity-federation service connections, a variable group and a pipeline environment
    (prod gets an approval check). Plus the pipelines and the PR build policies.

    It does NOT create infrastructure. Capacities, workspaces and groups are built by Terraform,
    run only by the pipeline. This script only creates what Terraform needs to start: identities,
    their permissions, and the empty resource group the capacities will live in.

.DESCRIPTION
    Run once, after bootstrap-backend.ps1 (and bootstrap-capacity.ps1 if you use F0), and after the
    code has been pushed to the Azure DevOps repo (pipelines need azure-pipelines.yml to exist).
    Idempotent: safe to re-run. No secret is ever created: both identities use federated credentials.

    Identities:
      managed identity  (-IdentityName)  Azure side: state storage, capacity create/pause/resume.
      service principal (-AppName)       Fabric and Microsoft Graph APIs (cannot use a managed identity
                                         from a pipeline). Needs no Azure roles.

    -Platform github skips every Azure DevOps step (service connections, variable groups, pipelines,
    policies); run scripts/bootstrap-github.ps1 afterwards. The default, azuredevops, is unchanged.

    Azure DevOps is driven through its REST API with a token from `az`. If the Azure subscription lives
    in a different tenant than the Azure DevOps organisation, pass -AzdoAuthSubscriptionId: a subscription
    your signed-in account can see in the organisation's tenant (only used to obtain the DevOps token).

    Tries to grant admin consent for the Graph application permissions Terraform needs
    (Group.ReadWrite.All, Directory.ReadWrite.All). That requires a Global Administrator /
    Privileged Role Administrator; if consent fails the script says so and carries on.

    Also enables the Fabric tenant settings the service principal needs (read/write admin APIs and
    workspace creation) for the SPN security group, which needs a Fabric administrator.

.EXAMPLE
    .\bootstrap-identity.ps1 -SubscriptionId <sub> -StateResourceGroup rg-fabricvending-tfstate `
        -StorageAccountName <storage> -AzdoOrganization https://dev.azure.com/<your-org> `
        -AzdoAuthSubscriptionId <sub in the DevOps tenant>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $StateResourceGroup,
    [Parameter(Mandatory)] [string] $StorageAccountName,
    [string] $AzdoOrganization       = "",   # Azure DevOps only, e.g. https://dev.azure.com/<your-org>
    [string] $AzdoProject            = "Fabric Vending",
    [string] $RepoName               = "",
    [string] $AzdoAuthSubscriptionId = "",
    [string] $CapacityResourceGroup  = "rg-fabricvending-capacity",
    [string] $Location               = "westeurope",
    [string] $AppName                = "sp-fabricvending-fabric",
    [string] $IdentityName           = "id-fabricvending-pipeline",
    [string[]] $Environments         = @("acc", "prod"),
    [string] $ApprovalEnvironment    = "prod",
    [string] $ContainerName          = "tfstate",
    [string] $FabricSpnGroupName     = "grp-fabricvending-spns",
    [ValidateSet("azuredevops", "github")] [string] $Platform = "azuredevops"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Platform -eq "azuredevops" -and -not $AzdoOrganization) {
    throw "-AzdoOrganization is required for -Platform azuredevops, e.g. https://dev.azure.com/<your-org>"
}
if (-not $RepoName) { $RepoName = $AzdoProject }
$AzdoOrganization = $AzdoOrganization.TrimEnd("/")
$azdoResource     = "499b84ac-1321-427f-aa17-267ca6975798"

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed" }
    return $out
}

function Get-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

if ($Platform -eq "azuredevops") {
# ── Azure DevOps REST helper ────────────────────────────────────────────────
$tokenSub = if ($AzdoAuthSubscriptionId) { $AzdoAuthSubscriptionId } else { $SubscriptionId }
$azdoToken = Invoke-Az account get-access-token --subscription $tokenSub --resource $azdoResource --query accessToken -o tsv

function Invoke-Azdo {
    param([string] $Method, [string] $Url, $Body = $null)
    $args2 = @{ Method = $Method; Uri = $Url; Headers = @{ Authorization = "Bearer $azdoToken" } }
    if ($null -ne $Body) {
        $args2.ContentType = "application/json"
        $args2.Body = $Body | ConvertTo-Json -Depth 20
    }
    Invoke-RestMethod @args2
}

$projEnc = [uri]::EscapeDataString($AzdoProject)
$proj    = Invoke-Azdo GET "$AzdoOrganization/_apis/projects/$projEnc`?api-version=7.1"
$projId  = $proj.id
$base    = "$AzdoOrganization/$projEnc"
$repo    = Invoke-Azdo GET "$base/_apis/git/repositories/$([uri]::EscapeDataString($RepoName))?api-version=7.1"

function Grant-AllPipelines([string] $ResourceType, [string] $ResourceId) {
    Invoke-Azdo PATCH "$base/_apis/pipelines/pipelinepermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1" `
        @{ allPipelines = @{ authorized = $true } } | Out-Null
}
}

# ── Azure side ──────────────────────────────────────────────────────────────
Invoke-Az account set --subscription $SubscriptionId | Out-Null
$tenantId = Invoke-Az account show --query tenantId -o tsv
$subName  = Invoke-Az account show --query name -o tsv

# 0. Resource provider the pipeline cannot register itself (its identity has no subscription-level rights)
if ((Invoke-Az provider show -n Microsoft.Fabric --query registrationState -o tsv) -ne "Registered") {
    Write-Host "Registering Microsoft.Fabric"
    Invoke-Az provider register -n Microsoft.Fabric --wait | Out-Null
}

# 1. Service principal (Fabric + Graph only)
$appId = Invoke-Az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) {
    Write-Host "Creating app registration: $AppName"
    $appId = Invoke-Az ad app create --display-name $AppName --query appId -o tsv
}
$appObjectId = Invoke-Az ad app show --id $appId --query id -o tsv
$spObjectId  = Invoke-Az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spObjectId) {
    Write-Host "Creating service principal"
    $spObjectId = Invoke-Az ad sp create --id $appId --query id -o tsv
}

# 2. User-assigned managed identity (Azure resources)
$miClientId = Invoke-Az identity list -g $StateResourceGroup --query "[?name=='$IdentityName'].clientId | [0]" -o tsv
if (-not $miClientId) {
    Write-Host "Creating managed identity: $IdentityName"
    $miClientId = Invoke-Az identity create -g $StateResourceGroup -n $IdentityName -l $Location --query clientId -o tsv
}
$miPrincipalId = Invoke-Az identity show -g $StateResourceGroup -n $IdentityName --query principalId -o tsv

# 3. Roles for the managed identity: state blobs + capacity resource group
$storageId = Invoke-Az storage account show -n $StorageAccountName -g $StateResourceGroup --query id -o tsv
if ((Invoke-Az group exists -n $CapacityResourceGroup) -ne "true") {
    Invoke-Az group create -n $CapacityResourceGroup -l $Location --output none | Out-Null
}
$capacityRgId = Invoke-Az group show -n $CapacityResourceGroup --query id -o tsv
foreach ($pair in @(@("Storage Blob Data Contributor", $storageId), @("Contributor", $capacityRgId))) {
    Write-Host "Role '$($pair[0])' -> $($pair[1])"
    Invoke-Az role assignment create --assignee-object-id $miPrincipalId --assignee-principal-type ServicePrincipal `
        --role $pair[0] --scope $pair[1] --output none | Out-Null
}

# 3b. Reader for the SPN on the capacity resource group only. The pipeline's AzureCLI task sets the
#     subscription for the Fabric service connection, which fails if the SPN can see no resource in it.
Write-Host "Role 'Reader' (service principal) -> $capacityRgId"
Invoke-Az role assignment create --assignee-object-id $spObjectId --assignee-principal-type ServicePrincipal `
    --role Reader --scope $capacityRgId --output none | Out-Null

# 4. Microsoft Graph application permissions + admin consent for the SPN (needs a privileged admin)
$graphAppId = "00000003-0000-0000-c000-000000000000"
foreach ($perm in "Group.ReadWrite.All", "Directory.ReadWrite.All") {
    $roleId = Invoke-Az ad sp show --id $graphAppId --query "appRoles[?value=='$perm'].id | [0]" -o tsv
    Invoke-Az ad app permission add --id $appId --api $graphAppId --api-permissions "$roleId=Role" --output none | Out-Null
}
$consented = $true
try { Invoke-Az ad app permission admin-consent --id $appId --output none | Out-Null }
catch { $consented = $false }
if ($consented) {
    # The call returning is not proof: read the app role assignments back. They can lag by a few seconds.
    $granted = 0
    for ($i = 0; $i -lt 6 -and $granted -lt 2; $i++) {
        Start-Sleep -Seconds ($(if ($i -eq 0) { 0 } else { 5 }))
        $granted = @((Invoke-Az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" --query "value[].appRoleId" -o tsv)).Where({ $_ }).Count
    }
    if ($granted -lt 2) {
        $consented = $false
        Write-Host "Admin consent did not show up in Graph after retries ($granted of 2 permissions granted)."
    }
}

# 5. Security group for the Fabric tenant setting "Service principals can use Fabric APIs"
$groupId = Invoke-Az ad group list --display-name $FabricSpnGroupName --query "[0].id" -o tsv
if (-not $groupId) {
    $groupId = Invoke-Az ad group create --display-name $FabricSpnGroupName --mail-nickname $FabricSpnGroupName --query id -o tsv
}
$isMember = Invoke-Az ad group member check --group $groupId --member-id $spObjectId --query value -o tsv
if ($isMember -ne "true") { Invoke-Az ad group member add --group $groupId --member-id $spObjectId | Out-Null }

# 5b. Fabric Administrator Entra role for the SPN (domains and other admin APIs need it).
#     Needs a privileged admin; if it fails the script says so and carries on.
$fabricAdminRoleId = "a9ea8996-122f-4c74-9520-8edcd192826c"
$fabricAdminAssigned = $false
try {
    $roleUrl = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments"
    $have = Invoke-Az rest --method get --url "$roleUrl`?`$filter=principalId eq '$spObjectId' and roleDefinitionId eq '$fabricAdminRoleId'" --query "value[0].id" -o tsv
    if (-not $have) {
        Write-Host "Assigning Fabric Administrator to the service principal"
        $file = New-TemporaryFile
        try {
            @{ principalId = $spObjectId; roleDefinitionId = $fabricAdminRoleId; directoryScopeId = "/" } |
                ConvertTo-Json | Set-Content -Path $file -Encoding utf8
            Invoke-Az rest --method post --url $roleUrl --headers "Content-Type=application/json" --body "@$file" --output none | Out-Null
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
    $fabricAdminAssigned = $true
}
catch { Write-Host "Could not assign Fabric Administrator automatically: $($_.Exception.Message)" }

# 5c. Fabric tenant settings the SPN needs, enabled for the SPN group only. Without them the Fabric
#     API rejects the SPN (InsufficientScopes) even with the Fabric Administrator role.
#     Needs a Fabric administrator (Fabric Administrator role or Global Administrator, via PIM).
$fabricApi = "https://api.fabric.microsoft.com/v1/admin/tenantsettings"
$requiredTenantSettings = @(
    "AllowServicePrincipalsUseReadAdminAPIs",   # domains lookup
    "AllowServicePrincipalsUseWriteAdminAPIs",  # domain creation
    "ServicePrincipalAccessGlobalAPIs"          # workspace creation
)
$tenantSettingsEnabled = $true
try {
    $current = (Invoke-Az rest --method get --resource "https://api.fabric.microsoft.com" --url $fabricApi -o json | ConvertFrom-Json).tenantSettings
    foreach ($name in $requiredTenantSettings) {
        $setting = $current | Where-Object { $_.settingName -eq $name }
        if (-not $setting) { throw "Tenant setting $name not found" }
        $groups = @(Get-Prop $setting "enabledSecurityGroups" | Where-Object { $_ })
        if ($setting.enabled -and ($groups.Count -eq 0 -or ($groups | Where-Object { $_.graphId -eq $groupId }))) { continue }
        Write-Host "Enabling Fabric tenant setting $name for group $FabricSpnGroupName"
        $newGroups = @($groups | ForEach-Object { @{ graphId = $_.graphId; name = $_.name } }) + @(@{ graphId = $groupId; name = $FabricSpnGroupName })
        $file = New-TemporaryFile
        try {
            @{ enabled = $true; enabledSecurityGroups = $newGroups } | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
            Invoke-Az rest --method post --resource "https://api.fabric.microsoft.com" --url "$fabricApi/$name/update" `
                --headers "Content-Type=application/json" --body "@$file" --output none | Out-Null
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}
catch { $tenantSettingsEnabled = $false; Write-Host "Could not enable Fabric tenant settings automatically: $($_.Exception.Message)" }

if ($Platform -eq "azuredevops") {
# ── Azure DevOps side ───────────────────────────────────────────────────────
# 6. Service connection helper (workload identity federation, manual) + matching federated credentials
function Ensure-ServiceConnection {
    param([string] $Name, [string] $ClientId, [ValidateSet("app", "identity")] [string] $Kind)

    $found = (Invoke-Azdo GET "$base/_apis/serviceendpoint/endpoints?endpointNames=$([uri]::EscapeDataString($Name))&api-version=7.1").value |
        Select-Object -First 1
    if (-not $found) {
        Write-Host "Creating service connection: $Name"
        $found = Invoke-Azdo POST "$base/_apis/serviceendpoint/endpoints?api-version=7.1" @{
            name        = $Name
            description = "Fabric Vending ($Kind), workload identity federation"
            type        = "azurerm"
            url         = "https://management.azure.com/"
            authorization = @{
                scheme     = "WorkloadIdentityFederation"
                parameters = @{ serviceprincipalid = $ClientId; tenantid = $tenantId }
            }
            data = @{
                environment      = "AzureCloud"
                scopeLevel       = "Subscription"
                subscriptionId   = $SubscriptionId
                subscriptionName = $subName
                creationMode     = "Manual"
            }
            serviceEndpointProjectReferences = @(@{
                projectReference = @{ id = $projId; name = $AzdoProject }
                name             = $Name
                description      = "Fabric Vending"
            })
        }
    }

    $authParams = Get-Prop (Get-Prop $found "authorization") "parameters"
    $issuer  = Get-Prop $authParams "workloadIdentityFederationIssuer"
    $subject = Get-Prop $authParams "workloadIdentityFederationSubject"
    if (-not $issuer -or -not $subject) {
        throw "Service connection '$Name' did not return a federation issuer/subject. Open it in Azure DevOps (Project settings > Service connections) and add the federated credential from its details manually, then re-run."
    }

    $credName = "azdo-$Name"
    if ($Kind -eq "app") {
        $have = Invoke-Az ad app federated-credential list --id $appObjectId --query "[].name" -o tsv
        if ($have -notcontains $credName) {
            Write-Host "Adding federated credential on app: $credName"
            $file = New-TemporaryFile
            try {
                @{ name = $credName; issuer = $issuer; subject = $subject; audiences = @("api://AzureADTokenExchange") } |
                    ConvertTo-Json | Set-Content -Path $file -Encoding utf8
                Invoke-Az ad app federated-credential create --id $appObjectId --parameters "@$file" --output none | Out-Null
            }
            finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        }
    }
    else {
        $have = Invoke-Az identity federated-credential list --identity-name $IdentityName -g $StateResourceGroup --query "[].name" -o tsv
        if ($have -notcontains $credName) {
            Write-Host "Adding federated credential on managed identity: $credName"
            Invoke-Az identity federated-credential create --name $credName --identity-name $IdentityName -g $StateResourceGroup `
                --issuer $issuer --subject $subject --audiences "api://AzureADTokenExchange" --output none | Out-Null
        }
    }

    Grant-AllPipelines "endpoint" $found.id
    return $found.id
}

# 7. Per environment: service connections, variable group (no secrets), pipeline environment.
#    Capacity name/size/region are NOT here: they live in parameters/environments/<env>.tfvars
#    and Terraform creates the capacity.
$me = Invoke-Azdo GET "$AzdoOrganization/_apis/connectionData?api-version=7.1-preview.1"
$approverId = $me.authenticatedUser.id

# Approval check helper: the apply stage waits for a human on the protected environment.
function Ensure-ApprovalCheck($AzEnv, [string] $Label) {
    $approvalType = "8c6f20a7-a545-4486-9777-f762fafe0d4d"
    $checks = Invoke-Azdo GET "$base/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$($AzEnv.id)&api-version=7.1-preview.1"
    if ($checks.value | Where-Object { $_.type.id -eq $approvalType }) { return }
    Write-Host "Adding approval check on $($AzEnv.name) (approver: $($me.authenticatedUser.providerDisplayName))"
    Invoke-Azdo POST "$base/_apis/pipelines/checks/configurations?api-version=7.1-preview.1" @{
        type     = @{ id = $approvalType; name = "Approval" }
        settings = @{
            approvers       = @(@{ id = $approverId })
            executionOrder  = "anyOrder"
            instructions    = "Review the Terraform plan before applying to $Label."
            minRequiredApprovers = 1
            requesterCannotBeApprover = $false
        }
        resource = @{ type = "environment"; id = "$($AzEnv.id)" }
        timeout  = 43200
    } | Out-Null
}

# "global" is the scope for tenant-wide stacks (tenant settings): own service connections,
# variable group and approval environment, so they do not depend on any workspace environment.
$GlobalScope = "global"
foreach ($EnvironmentName in (@($Environments) + $GlobalScope)) {
    Write-Host ""
    Write-Host "== Environment: $EnvironmentName =="

    $azureScId  = Ensure-ServiceConnection -Name "sc-fabricvending-azure-$EnvironmentName"  -ClientId $miClientId -Kind identity
    $fabricScId = Ensure-ServiceConnection -Name "sc-fabricvending-fabric-$EnvironmentName" -ClientId $appId      -Kind app

    $groupName = "fabricvending-$EnvironmentName"
    $values = [ordered]@{
        AZURE_TENANT_ID              = $tenantId
        AZURE_SUBSCRIPTION_ID        = $SubscriptionId
        AZURE_CLIENT_ID              = $miClientId
        AZURE_SERVICE_CONNECTION_ID  = $azureScId
        FABRIC_CLIENT_ID             = $appId
        FABRIC_SERVICE_CONNECTION_ID = $fabricScId
        TFSTATE_RESOURCE_GROUP       = $StateResourceGroup
        TFSTATE_STORAGE_ACCOUNT      = $StorageAccountName
        TFSTATE_CONTAINER            = $ContainerName
    }
    $vars = @{}
    foreach ($k in $values.Keys) { $vars[$k] = @{ value = [string]$values[$k]; isSecret = $false } }
    $vgBody = @{
        type = "Vsts"; name = $groupName; variables = $vars
        variableGroupProjectReferences = @(@{ name = $groupName; projectReference = @{ id = $projId; name = $AzdoProject } })
    }
    $vg = (Invoke-Azdo GET "$base/_apis/distributedtask/variablegroups?groupName=$groupName&api-version=7.1").value | Select-Object -First 1
    if ($vg) {
        Write-Host "Updating variable group: $groupName"
        $vg = Invoke-Azdo PUT "$base/_apis/distributedtask/variablegroups/$($vg.id)?api-version=7.1" $vgBody
    }
    else {
        Write-Host "Creating variable group: $groupName"
        $vg = Invoke-Azdo POST "$base/_apis/distributedtask/variablegroups?api-version=7.1" $vgBody
    }
    Grant-AllPipelines "variablegroup" $vg.id

    $envName = "fabricvending-$EnvironmentName"
    $azEnv = (Invoke-Azdo GET "$base/_apis/distributedtask/environments?name=$envName&api-version=7.1").value | Select-Object -First 1
    if (-not $azEnv) {
        Write-Host "Creating environment: $envName"
        $azEnv = Invoke-Azdo POST "$base/_apis/distributedtask/environments?api-version=7.1" @{ name = $envName; description = "Fabric Vending ($EnvironmentName)" }
    }
    Grant-AllPipelines "environment" $azEnv.id

    # Approval check: the apply stage waits for a human on the protected environment.
    if ($EnvironmentName -eq $ApprovalEnvironment -or $EnvironmentName -eq $GlobalScope) { Ensure-ApprovalCheck $azEnv $EnvironmentName }
}

# 8. Pipelines
function Ensure-Pipeline([string] $Name, [string] $YamlPath) {
    $p = (Invoke-Azdo GET "$base/_apis/pipelines?api-version=7.1").value | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $p) {
        Write-Host "Creating pipeline: $Name"
        $p = Invoke-Azdo POST "$base/_apis/pipelines?api-version=7.1" @{
            name          = $Name
            folder        = "\"
            configuration = @{
                type       = "yaml"
                path       = $YamlPath
                repository = @{ id = $repo.id; name = $repo.name; type = "azureReposGit" }
            }
        }
    }
    return $p.id
}
$deployPipelineId   = Ensure-Pipeline "fabricvending-deploy"   "/azure-pipelines.yml"
$validatePipelineId = Ensure-Pipeline "fabricvending-validate" "/azure-pipelines-validate.yml"
$tenantSettingsPipelineId = Ensure-Pipeline "fabricvending-tenant-settings" "/azure-pipelines-tenant-settings.yml"

# 9. Build-validation policies on main: offline checks + a Terraform plan on every PR
$buildPolicyType = "0609b952-1397-4640-95ec-e00a01b2c241"
$policies = (Invoke-Azdo GET "$base/_apis/policy/configurations?api-version=7.1").value
# The tenant settings plan only runs for PRs that touch the tenant settings files.
$tenantSettingsPaths = "/tenant_settings/*;/parameters/tenant-settings/*;/azure-pipelines-tenant-settings.yml;/.azuredevops/steps/tenant-settings.yml"
foreach ($pair in @(
        @($validatePipelineId, "Validate", ""),
        @($deployPipelineId, "Terraform plan", ""),
        @($tenantSettingsPipelineId, "Tenant settings plan", $tenantSettingsPaths))) {
    $has = $policies | Where-Object {
        $_.type.id -eq $buildPolicyType -and $_.isDeleted -ne $true -and
        [string](Get-Prop $_.settings "buildDefinitionId") -eq [string]$pair[0]
    }
    if ($has) { continue }
    Write-Host "Adding build policy on main: $($pair[1])"
    Invoke-Azdo POST "$base/_apis/policy/configurations?api-version=7.1" @{
        isEnabled  = $true
        isBlocking = $true
        type       = @{ id = $buildPolicyType }
        settings   = @{
            buildDefinitionId      = $pair[0]
            displayName            = $pair[1]
            queueOnSourceUpdateOnly = $true
            manualQueueOnly        = $false
            validDuration          = 720
            scope                  = @(@{ repositoryId = $repo.id; refName = "refs/heads/main"; matchKind = "Exact" })
        } + $(if ($pair[2]) { @{ filenamePatterns = @($pair[2] -split ";") } } else { @{} })
    } | Out-Null
}
}

Write-Host ""
Write-Host "Done."
Write-Host "  Managed identity (Azure): $IdentityName (client id $miClientId)"
Write-Host "  Service principal (Fabric/Entra): $AppName (client id $appId)"
Write-Host "  Service principal object id (add to capacity admins in the tfvars): $spObjectId"
if ($Platform -eq "azuredevops") {
    Write-Host "  Environments: $($Environments -join ', ')"
    Write-Host "  Pipelines: $AzdoOrganization/$projEnc/_build"
} else {
    Write-Host "  Next: run scripts/bootstrap-github.ps1 to wire GitHub Actions."
}
Write-Host ""
Write-Host "Remaining steps that cannot be scripted from here:"
if (-not $fabricAdminAssigned) {
    Write-Host " - Assign the Entra role 'Fabric Administrator' to service principal '$AppName' (object id $spObjectId):"
    Write-Host "   Entra admin center > Roles & administrators > Fabric Administrator > Add assignments."
}
if (-not $consented) {
    Write-Host " 1. A Global/Privileged Role Administrator must grant admin consent:"
    Write-Host "      az ad app permission admin-consent --id $appId"
}
if (-not $tenantSettingsEnabled) {
    Write-Host " - A Fabric administrator must enable these tenant settings for group '$FabricSpnGroupName':"
    Write-Host "   $($requiredTenantSettings -join ', ')"
    Write-Host "   (Fabric admin portal > Tenant settings > Developer settings / Admin API settings), or re-run this script as a Fabric administrator."
}
Write-Host " - The service principal '$AppName' must be a capacity admin so Terraform can assign workspaces to the capacity:"
Write-Host "   put its object id ($spObjectId) in capacity_extra_admins in each environment tfvars."
