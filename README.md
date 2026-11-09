<p align="center">
  <img src="assets/fabric-vending-logo-640.png" alt="Fabric Vending Machine logo: a glowing hexagon around an F with a cowboy hat, next to a V" width="260">
</p>

<h1 align="center">Fabric Vending Machine</h1>

<p align="center">
  Stop click-ops-ing your Microsoft Fabric tenant. Workspaces, role groups, capacities and tenant settings, all as code, all through a pipeline.
</p>

<p align="center">
  <img alt="Terraform 1.12+" src="https://img.shields.io/badge/Terraform-%E2%89%A5%201.12-7B42BC?logo=terraform&logoColor=white">
  <img alt="Fabric provider 1.11+" src="https://img.shields.io/badge/microsoft%2Ffabric-%E2%89%A5%201.11-0FB5A0">
  <img alt="Azure DevOps pipelines" src="https://img.shields.io/badge/CI%2FCD-Azure%20DevOps-0078D7?logo=azuredevops&logoColor=white">
  <img alt="GitHub Actions" src="https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

Terraform for Microsoft Fabric: capacities, workspaces, their Entra security groups and role assignments, domains and tenant settings. Nothing is hardcoded: your tenant lives in `.tfvars` files you create, and it runs against any Fabric tenant from Azure DevOps or GitHub Actions.

## How it runs

Terraform never runs from a laptop. A few one-time bootstrap scripts prepare state storage and two identities, then three pipelines do everything else:

| Pipeline | What it does | Runs on |
|---|---|---|
| `validate` | Offline checks: format, validate, mocked-provider tests for both stacks, shell syntax. | Every pull request (required). |
| `deploy` | Workspaces, role groups, capacities. A pull request gets a plan per environment. A push to `main` plans and applies `acc`, then plans and applies `prod` (planned after acc, so it sees what acc created). | Pull requests and pushes to `main`. |
| `tenant-settings` | Tenant-wide Fabric settings in their own stack and state, behind their own approval. | Only when the settings or that stack change. |

Authentication is workload identity federation, so no secret exists anywhere: a user-assigned managed identity for Azure and a service principal for the Fabric and Microsoft Graph APIs. Capacities are resumed before a plan or apply and paused afterwards, so they only bill while Terraform works.

**Status:** onboarded end to end from a fresh clone on both Azure DevOps and GitHub Actions, in two different tenants, in November 2026. Everything that went wrong on the way is fixed in the scripts and covered below.

## What it provisions

For each workspace entry you define:

- a **Fabric workspace**, assigned to the environment's capacity
- **4 Entra security groups** (`Admin`, `Contributor`, `Viewer`, `Member`) with a fixed naming convention
- **workspace role assignments** linking those groups to the workspace
- the workspace's **Fabric domain** (created by the first environment, looked up by the others) and the domain assignment
- optional: **Git integration** (Azure DevOps or GitHub), usually on a DEV workspace
- optional: an **owner group** nested into each Admin group, and a **deployment service principal** as admin

Per environment it also creates the **Fabric capacity** (F2 and up; F0 through a script, see [F0 capacities](#f0-capacities)).

```
Fabric tenant
├── Domain: Finance
├── Capacity (acc)
│   └── Workspace: Finance UAT ── domain Finance
│       ├── Entra group FABRIC_WORKSPACE_FINANCE_UAT_ADMIN
│       ├── Entra group FABRIC_WORKSPACE_FINANCE_UAT_CONTRIBUTOR
│       ├── Entra group FABRIC_WORKSPACE_FINANCE_UAT_VIEWER
│       └── Entra group FABRIC_WORKSPACE_FINANCE_UAT_MEMBER
└── Capacity (prod)
    └── Workspace: Finance ────── domain Finance   (PROD has no suffix)
```

The pipelines deploy two environments, `acc` (the UAT stage) and `prod` (PROD). A DEV stage is optional: see [Adding a DEV environment](#adding-a-dev-environment).

## Getting started

### The quick way: let an AI assistant drive

Open the repository in Claude Code and run `/onboard` (other assistants: point them at [AGENTS.md](AGENTS.md)). It finds out what it can, asks about the rest, runs the read-only checks, writes your tfvars, and runs each bootstrap script only after you confirm it by name. It follows exactly the steps below.

### What you need

**Tools** on the machine you bootstrap from:

| Tool | Why | macOS | Windows |
|---|---|---|---|
| Azure CLI (`az`) 2.60+ | every script | `brew install azure-cli` | `winget install Microsoft.AzureCLI` |
| PowerShell 7 (`pwsh`) | the bootstrap scripts | `brew install powershell` | `winget install Microsoft.PowerShell` |
| Terraform 1.12+ | offline checks only | `brew install hashicorp/tap/terraform` | `winget install Hashicorp.Terraform` |
| Git | pushing the code | built in | `winget install Git.Git` |
| GitHub CLI (`gh`) | GitHub path only | `brew install gh` | `winget install GitHub.cli` |
| `az devops` extension | Azure DevOps path only | `az extension add --name azure-devops` | same |

On Linux install them from each tool's documentation. In a slim container `pwsh` can stop with "Couldn't find a valid ICU package": install `libicu`, or set `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`.

**Access:**

- An **Azure subscription** in the Fabric tenant, where you can create resource groups and role assignments (Owner, or Contributor + User Access Administrator).
- For the bootstrap only, an account with **Global Administrator** (or Privileged Role Administrator **and** Fabric Administrator) in that tenant. With PIM, activate the role before you start; activations expire, so re-activate if a script suddenly reports "Insufficient privileges".
- **Azure DevOps**: an organisation where you can create a project, or **GitHub**: a repository you administer.

You do **not** need an existing capacity or service principal: Terraform creates the capacities and `bootstrap-identity.ps1` creates the identities.

### 1. Pick the right account and tenant

`az` can be signed in to several accounts at once, and the default one is often not the one for the Fabric tenant. Check before anything else:

```bash
az account list --all --query "[].{name:name, id:id, tenant:tenantId, user:user.name}" -o table
az login --tenant <fabric-tenant-id>          # if the subscription is not listed under the right account
```

Every script takes `-SubscriptionId` explicitly and leaves your default subscription alone. If the portal shows a subscription that `az` does not, the portal is using a different account; sign in with that one. A subscription created minutes ago can take a while to appear (`az account clear`, then `az login`, refreshes it).

**Which account is the capacity admin?** It must be a native member of the tenant, for example `admin@yourtenant.onmicrosoft.com`. A guest (`name_domain.com#EXT#@...`) is rejected. A tenant created with a personal Microsoft account shows that account as a *member* whose UPN still contains `#EXT#`; Fabric rejects that too. Use a native account as capacity admin and put **every** account you sign in to Fabric with in `workspace_admin_user_object_ids`.

### 2. Run the read-only preflight

```powershell
git clone https://github.com/MrKruge/fabric-vending-machine.git
cd fabric-vending-machine
pwsh scripts/preflight.ps1 -SubscriptionId <subscription-id> -Location swedencentral -Sku F2 `
    -AdminEmail admin@yourtenant.onmicrosoft.com
```

It changes nothing. It shows which account and tenant it uses, then checks that the subscription is visible, the SKU is offered in the region, the account can read the directory (a guest or an unactivated PIM role cannot), the Power BI service principal is enabled, and every capacity admin is a native member. It tells you the exact UPN to use. `[todo] Microsoft.Fabric not registered` is fine: `bootstrap-identity.ps1` registers it.

### 3. Write your configuration

```bash
cp parameters/environments/acc.tfvars.example  parameters/environments/acc.tfvars
cp parameters/environments/prod.tfvars.example parameters/environments/prod.tfvars
cp parameters/workspaces/examples/example-finance.tfvars parameters/workspaces/finance.tfvars
```

- In both environment files fill in the tenant id, subscription id, capacity name, SKU, region (the same one you pass as `-Location`), the capacity admin's UPN, and the object ids of the people who should be workspace admins (`az ad user show --id <upn> --query id -o tsv`). Leave `capacity_extra_admins` for now.
- In the workspace file set the names and the `data_domain`. Every `data_domain` becomes a Fabric domain automatically. Files in `parameters/workspaces/examples/` are templates and never deployed.
- These files hold ids, never secrets. They are committed, and the pipelines read them.

Check them offline:

```bash
terraform fmt -recursive && (cd workspace_vending && terraform init -backend=false && terraform validate && terraform test)
```

### 4. Create the state storage

```powershell
pwsh scripts/bootstrap-backend.ps1 -SubscriptionId <subscription-id> -Location swedencentral `
    -StorageAccountName <globally-unique-name>
```

Creates `rg-fabricvending-tfstate`, the storage account (Entra ID access only, no shared keys, versioning on) and the `tfstate` container. There is nothing to `terraform init` afterwards: the pipelines configure the backend themselves.

### 5a. Azure DevOps

1. **Create the project and push the code.** Pushing first is safe: Azure DevOps only runs a pipeline after it has been created, and step 2 creates it. After that, bring the tfvars in through a pull request ([step 6](#6-first-deploy)); a push to `main` without them only fails at the first step, nothing is applied.

   ```bash
   az devops project create --organization https://dev.azure.com/<org> --name "Fabric Vending" --visibility private
   git remote add azdo "https://dev.azure.com/<org>/Fabric%20Vending/_git/Fabric%20Vending"
   git push azdo main
   ```

2. **Identities, service connections, pipelines and policies.** Run it with your admin role active:

   ```powershell
   pwsh scripts/bootstrap-identity.ps1 -SubscriptionId <subscription-id> -Location swedencentral `
       -StateResourceGroup rg-fabricvending-tfstate -StorageAccountName <storage-account> `
       -AzdoOrganization https://dev.azure.com/<org> -AzdoProject "Fabric Vending" `
       -AzdoAuthSubscriptionId <subscription-in-the-devops-tenant>
   ```

   `-AzdoAuthSubscriptionId` is only needed when the Azure DevOps organisation is connected to a **different** Entra tenant than the Fabric subscription. It is any subscription your account can see in the **organisation's** tenant (Azure DevOps > Organization settings > Microsoft Entra shows which tenant that is). It is only used to get a DevOps token; nothing is created in it.

   The script creates the managed identity and service principal, their roles and permissions, and per environment (`acc`, `prod`, plus `global` for tenant settings) two service connections, a variable group and a pipeline environment, approval checks on `prod` and `global`, the three pipelines and the build policies on `main`. It ends with what is still missing, if anything, and the service principal's object id.

### 5b. GitHub Actions

1. **Sign in to GitHub with the `workflow` scope** (needed to push `.github/workflows`), create your repository and push. Pushing is safe: the workflows skip until `parameters/environments/acc.tfvars` and `prod.tfvars` exist on `main`.

   ```bash
   gh auth login -s workflow                    # or: gh auth refresh -s workflow
   gh repo create <owner>/<repo> --private
   git remote add github https://github.com/<owner>/<repo>.git
   git push github main
   ```

2. **Identities and permissions**, with your admin role active:

   ```powershell
   pwsh scripts/bootstrap-identity.ps1 -Platform github -SubscriptionId <subscription-id> -Location swedencentral `
       -StateResourceGroup rg-fabricvending-tfstate -StorageAccountName <storage-account>
   ```

3. **Wire GitHub**: federated credentials, repository variables and the `acc`, `prod` and `global` environments. Try it with `-DryRun` first.

   ```powershell
   pwsh scripts/bootstrap-github.ps1 -SubscriptionId <subscription-id> -StateResourceGroup rg-fabricvending-tfstate `
       -StorageAccountName <storage-account> -Repository <owner>/<repo> -ReviewerLogin <your-github-login>
   ```

   It reads the environments back and says whether `prod` and `global` really have a reviewer. Required reviewers need a public repository, or GitHub Team/Enterprise for a private one. Without them a merge applies `acc` and then `prod` with nobody approving.

### 6. First deploy

1. Put the service principal object id that `bootstrap-identity.ps1` printed into `capacity_extra_admins` in both environment files, so the pipeline can assign workspaces to the capacities.
2. Commit the tfvars and workspace files on a branch and open a pull request. `validate` and a plan per environment run on it. Read the plans.
3. Merge. `deploy` plans and applies `acc`, then plans `prod` and applies it (after approval, where a reviewer is set).
4. Check the result: both capacities exist and are paused, the workspaces are active with their domain, and your accounts are in the Admin groups.

On Azure DevOps a build you queue by hand does not satisfy a pull request's build policy. After fixing a failed plan, push a commit, or re-queue the policy itself: `az repos pr policy list --id <pr>` to find the evaluation id, then `az repos pr policy queue --id <pr> --evaluation-id <id>`.

## Identities and permissions

| Identity | Used for | Gets |
|---|---|---|
| User-assigned **managed identity** `id-fabricvending-pipeline` | State storage, capacity create/pause/resume | Storage Blob Data Contributor on the state account, Contributor on `rg-fabricvending-capacity` |
| **Service principal** `sp-fabricvending-fabric` (app registration) | Fabric and Microsoft Graph APIs: workspaces, role assignments, groups, domains | Graph application permissions `Group.ReadWrite.All` and `Directory.ReadWrite.All`, the Entra role **Fabric Administrator**, Reader on `rg-fabricvending-capacity`, and the three Fabric tenant settings below for its group `grp-fabricvending-spns` |

The Fabric and Graph APIs cannot be called with a managed identity from a pipeline, hence the second identity. Together these rights are close to tenant administration for anyone who can get a change applied from `main`. Protect `main` with required reviews, keep reviewers on the `prod` and `global` environments, and limit who can edit the pipelines.

The tenant settings the service principal needs: `AllowServicePrincipalsUseReadAdminAPIs`, `AllowServicePrincipalsUseWriteAdminAPIs` and `ServicePrincipalAccessGlobalAPIs`. `bootstrap-identity.ps1` enables them for `grp-fabricvending-spns`; the tenant settings stack refuses to turn them off.

## Troubleshooting

`scripts/preflight.ps1` checks the first group before you start. The rest are things real first runs ran into.

**Before you start**

- **Wrong tenant or account.** `az` used another signed-in account. See [step 1](#1-pick-the-right-account-and-tenant).
- **"Insufficient privileges" from Graph.** The account is a guest in the tenant, or its admin role is not activated in PIM. Activate it, or use a native admin account, and re-run. All scripts are safe to re-run.
- **Power BI Service disabled** (`AADSTS500014 ... is disabled`). A Global Administrator enables it: Entra > Enterprise applications > Power BI Service > Properties > "Enabled for users to sign-in" = Yes. In a tenant that never used Fabric, sign in once to app.fabric.microsoft.com so it exists.
- **Capacity admin rejected** (`Invalid principal name`, or `All provided principals must be existing, user or service principals`): a guest or `#EXT#` account. Use a native member's UPN; some accounts have no `mail`, so use the UPN, not the email address.
- **Capacity region.** The region must suit the tenant's home geography, and a busy region can be full. `Location needs to match the PowerBI cluster location` means the region is wrong for the tenant. List what is offered: `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Fabric/skus?api-version=2023-11-01"`.

**During the bootstrap**

- **Graph permissions not granted.** The script grants them and reads them back. If it says they are missing, activate Global Administrator or Privileged Role Administrator and re-run it.
- **Tenant settings refer to a deleted group** (an earlier onboarding was cleaned up). Fabric rejects any update that still names it; the script now drops deleted groups and says so.
- **`AADSTS700213: No matching federated identity record`** in the first plan. A federated credential from an earlier onboarding (another project or repository) had the same name and a different subject. The scripts now compare the subject and replace such a credential; re-run `bootstrap-identity.ps1` (Azure DevOps) or `bootstrap-github.ps1`.
- **Azure DevOps in another tenant than the subscription.** Pass `-AzdoAuthSubscriptionId` ([step 5a](#5a-azure-devops)). Do not pass `--tenant` to `az account get-access-token` yourself; it can fall back to a different signed-in account.
- **Azure CLI cannot edit PIM eligibility** (`AADSTS65002`); do that in the Entra portal.

**In the pipeline**

- **Terraform 1.12 or newer.** The azurerm backend supports Azure DevOps OIDC from 1.12.0.
- **A paused capacity breaks the plan.** The pipeline resumes it first and pauses it afterwards. Capacity transitions can take minutes; don't resume while it is pausing.
- **Keeping a capacity running** for a demo: set `capacity_keep_running = true` in that environment's tfvars through a pull request, and back to `false` afterwards (a running capacity is billed). `scripts/capacity.sh` reads it.
- **"Instance cannot be destroyed" for `fabric_domain.this[...]`.** Domains are protected from deletion. When no workspace uses a domain any more (removed, or `data_domain` renamed), keep its name in `domains` in `acc.tfvars` and the domain stays. To really delete one, do it in a pull request that drops the name and also takes `prevent_destroy` out of `workspace_vending/domains.tf` for that one change; put it back afterwards.
- **Domain not assigned in a pull request plan for prod.** On a pull request both environments are planned side by side, so prod cannot find a domain that acc has not created yet and leaves the assignment out of that plan. After merging, prod is planned after acc applied and gets it.
- **Fabric API calls from the CLI need MFA.** For ad hoc reads: `az login --tenant <tenant> --scope https://api.fabric.microsoft.com/.default`.

## Adding a DEV environment

The pipelines deploy `acc` and `prod`. To also deploy the `*_DEV` workspace entries, which is where Git integration usually lives:

1. `cp parameters/environments/dev.tfvars.example parameters/environments/dev.tfvars` and fill it in. Leave `create_domains = true` in `acc.tfvars` and `false` in `dev.tfvars`: acc's state owns the domains, and moving them would make acc's plan want to delete them. The first time a new domain appears, dev deploys before acc has created it and assigns it on the next run. Set `git_connection_id` if a workspace uses Git integration.
2. Re-run the bootstrap with `-Environments dev,acc,prod` (`bootstrap-identity.ps1`, and `bootstrap-github.ps1` on GitHub).
3. Azure DevOps: in `azure-pipelines.yml` add a `dev` stage template before `acc`, and give `acc` `planAfter: Apply_dev` and `applyDependsOn: [Apply_dev]`. GitHub: in `.github/workflows/deploy.yml` add `dev` to the pull request matrix and the readiness check, and add `plan-dev` and `apply-dev` jobs before `plan-acc`, which then `needs: apply-dev`.

## Tenant settings

Fabric tenant settings are tenant-wide, so they live in their own Terraform stack (`tenant_settings/`, next to `workspace_vending/`), their own state and their own pipeline. It runs only when `parameters/tenant-settings/` or the stack changes, and does nothing until `parameters/tenant-settings/tenant-settings.tfvars` exists. A pull request gets a plan; a push to `main` plans, then waits for approval on the `global` environment before it applies.

Start from the live tenant and keep only what you want governed:

```powershell
az login --tenant <tenant-id>
pwsh scripts/get-fabric-tenant-settings.ps1 -TenantId <tenant-id> -UseAzCli -OutputTfvars
```

That writes every setting as a `fabric_tenant_settings` map. Copy the entries you want into `parameters/tenant-settings/tenant-settings.tfvars` (start from the `.example` next to it). Settings that are not listed are left alone, and removing an entry stops managing it without resetting it. `delegated_to` lists Entra group display names; empty means the whole tenant. The three settings the pipeline's own service principal depends on cannot be disabled here: the plan refuses it.

## F0 capacities

The `azurerm` provider only creates F2 and up. F0 is offered in very few regions (West Central US and two canary regions), so it needs a tenant with a US home region. Create it with the script, then let Terraform look it up:

```powershell
pwsh scripts/bootstrap-capacity.ps1 -SubscriptionId <subscription-id> -CapacityName <name> -Sku F0 `
    -Location westcentralus -AdminEmail admin@yourtenant.onmicrosoft.com,<pipeline-spn-object-id>
```

Then set `create_capacity = true`, `capacity_sku = "F0"` and `capacity_name = "<name>"` in the environment's tfvars. Terraform does not manage this capacity's admins, so include the pipeline service principal's object id in `-AdminEmail` (re-run the script after `bootstrap-identity.ps1`).

## Starting over in the same tenant

Re-running the bootstrap scripts is safe, also after an earlier onboarding: they reuse what exists and repair stale federated credentials and deleted groups in tenant settings. To remove an onboarding completely, delete what it created: the resource groups `rg-fabricvending-capacity` and `rg-fabricvending-tfstate`, the app registration `sp-fabricvending-fabric`, the group `grp-fabricvending-spns`, the workspaces and their `FABRIC_WORKSPACE_*` groups, and the domains (Terraform protects domains from deletion on purpose). Then the service connections, variable groups and pipelines in Azure DevOps, or the variables and environments in GitHub.

## Local development

Only offline commands run locally:

```bash
terraform fmt -recursive && (cd workspace_vending && terraform init -backend=false && terraform validate && terraform test)
(cd tenant_settings && terraform init -backend=false && terraform validate && terraform test)
for f in scripts/*.sh tests/*.sh; do bash -n "$f"; done && bash tests/capacity-script.sh && bash tests/merge-workspaces.sh
```

`terraform plan` and `apply` run only in the pipelines, with the pipeline identities.

## Drift detection

`scripts/check-alignment.ps1` checks that the expected workspaces and Entra groups exist and that the role assignments follow the naming convention, so a role assignment added by hand in the Fabric portal shows up immediately:

```powershell
Connect-AzAccount
pwsh scripts/check-alignment.ps1 -GroupPrefix "FABRIC_WORKSPACE" -WorkspaceNames @("Finance","Sales")
```

## Other scripts

| Script | Why | Usage |
|---|---|---|
| `scripts/check-storage-format.sh` | The Fabric provider does not manage per-dataset storage format (Large/Small); it is a Power BI REST setting. Inspect or fix one workspace. | `bash scripts/check-storage-format.sh <workspace_id> [--set-large\|--set-small]` |
| `scripts/set-storage-format.sh` | Bulk version: reads `workspace_storage_formats` from Terraform and reconciles every vended workspace to its `default_storage_format`. For a pipeline step after the apply. | `bash scripts/set-storage-format.sh workspace_vending [--dry-run] [--datasets]` |
| `scripts/merge-workspaces.sh` | Merges every `parameters/workspaces/*.tfvars` (not `examples/`) into one `workspaces` map. The pipelines run it. | `bash scripts/merge-workspaces.sh parameters/workspaces > merged_workspaces.auto.tfvars` |
| `scripts/get-fabric-tenant-settings.ps1` | Exports the live tenant settings as tfvars, and with `-CheckPublishToWeb` lists reports that are publicly exposed. | `pwsh scripts/get-fabric-tenant-settings.ps1 -TenantId <tenant-id> [-UseAzCli] [-OutputTfvars] [-CheckPublishToWeb]` |

## File structure

```
├── workspace_vending/                    # Terraform stack: capacities, workspaces, groups, domains (state per environment)
│   ├── terraform.tf, providers.tf        # providers and their identities
│   ├── backend.tf                        # explains where the backend comes from (the pipelines)
│   ├── variables.tf, locals.tf, main.tf
│   ├── capacity.tf                       # the environment's capacity
│   ├── workspace.tf                      # workspaces, groups, role assignments, Git integration
│   ├── domains.tf                        # domains: created by the first environment, looked up by the others
│   ├── outputs.tf
│   └── tests/                            # terraform test, mocked providers
├── tenant_settings/                      # Terraform stack: tenant settings (one tenant-wide state)
├── azure-pipelines.yml                   # Azure DevOps: deploy
├── azure-pipelines-validate.yml          # Azure DevOps: offline checks (build policy)
├── azure-pipelines-tenant-settings.yml   # Azure DevOps: tenant settings
├── .azuredevops/                         # Azure DevOps stage and step templates
├── .github/                              # GitHub Actions workflows and the shared Terraform action
├── tests/                                # script tests (fake az)
├── parameters/
│   ├── environments/                     # acc / prod (/ dev) .tfvars.example → copy to .tfvars
│   ├── tenant-settings/                  # tenant-settings.tfvars.example → copy to .tfvars
│   └── workspaces/
│       ├── examples/                     # templates, never deployed
│       └── <name>.tfvars                 # one file per logical workspace
├── scripts/
│   ├── preflight.ps1                     # read-only first-run checks
│   ├── bootstrap-backend.ps1             # state storage
│   ├── bootstrap-identity.ps1            # identities, permissions, Azure DevOps wiring
│   ├── bootstrap-github.ps1              # GitHub Actions wiring
│   ├── bootstrap-capacity.ps1            # F0 capacities only
│   ├── capacity.sh                       # resume/suspend, used by both CI systems
│   ├── merge-workspaces.sh               # merge workspace files for the plan
│   ├── get-fabric-tenant-settings.ps1    # export tenant settings
│   ├── check-alignment.ps1               # drift detection
│   └── check-storage-format.sh, set-storage-format.sh, install-terraform.sh, tfvar.sh
├── AGENTS.md                             # guidance for AI assistants
└── .claude/skills/onboard/               # the /onboard skill
```

## Variables reference

| Variable | Default | Description |
|---|---|---|
| `tenant_id` | required | Entra tenant id |
| `workspace_environment_suffix` | required | `DEV`, `UAT` or `PROD`: which workspace entries this environment deploys |
| `workspaces` | required | Map of workspace definitions (merged from `parameters/workspaces/*.tfvars`, see below) |
| `create_capacity` | `false` | `true` to have Terraform create the environment's capacity |
| `capacity_name` | `null` | Capacity name (3-63 lowercase letters/digits). Required with `create_capacity` |
| `capacity_sku` | `"F2"` | F2 and up are created by Terraform; F0 by `bootstrap-capacity.ps1` |
| `capacity_resource_group` | `null` | Resource group for the capacity (`bootstrap-identity.ps1` creates `rg-fabricvending-capacity`) |
| `capacity_location` | `"West Europe"` | Region of the capacity |
| `capacity_admin_email` | `null` | UPN of a native member who administers the capacity |
| `capacity_extra_admins` | `[]` | More capacity admins: the pipeline service principal's object id goes here |
| `capacity_subscription_id` | `null` | Subscription of the capacity resource group |
| `capacity_keep_running` | `false` | Read by `capacity.sh`: leave the capacity running after an apply |
| `fabric_capacity_id` / `fabric_capacity_name` | `null` | Use an existing capacity instead of creating one |
| `create_domains` | `false` | `true` in the first environment the pipeline deploys (acc), `false` in the others |
| `domains` | `[]` | Extra domains no workspace uses yet; every workspace `data_domain` is included automatically |
| `workspace_admin_user_object_ids` | `[]` | Users added to every workspace's Admin group |
| `group_prefix` | `"FABRIC_WORKSPACE"` | Prefix of the Entra group names |
| `owner_group_display_name` | `null` | Existing Entra group nested into each Admin group |
| `deployment_spn_object_id` | `null` | Service principal made admin of every workspace |
| `git_connection_id` | `null` | Fabric Git connection id, needed for Git integration |
| `fabric_spn_client_id`, `azure_client_id`, `*_service_connection_id` | `null` | Set by the pipelines, never in tfvars |

### Workspace definition

```hcl
workspaces = {
  finance_UAT = {
    display_name           = "Finance"       # the stage suffix is added (Finance UAT); PROD has none
    data_domain            = "Finance"       # Fabric domain, created automatically; "" for none
    environment            = "UAT"           # DEV, UAT or PROD
    git_integration        = false           # optional, usually only on DEV
    git_provider_type      = "AzureDevOps"   # or "GitHub"
    git_organization_name  = "your-org"
    git_project_name       = "Your Project"  # Azure DevOps only
    git_repository_name    = "your-repo"
    git_branch_name        = "main"          # optional
    git_directory_name     = "/workspaces/Finance" # optional
    default_storage_format = "Large"         # optional, Large or Small
    assign_capacity        = true            # optional; false for a Pro workspace
  }
}
```

Group names are `<group_prefix>_<WORKSPACE_NAME>_<ENV>_<ROLE>`, for example `FABRIC_WORKSPACE_FINANCE_UAT_CONTRIBUTOR`. PROD has no environment part: `FABRIC_WORKSPACE_FINANCE_VIEWER`.

## Outputs

| Output | Description |
|---|---|
| `workspace_ids` | Workspace key → Fabric workspace id |
| `domain_ids` | Domain name → Fabric domain id |
| `aad_group_object_ids` | Workspace role key → Entra group object id |
| `workspace_storage_formats` | Workspace id → storage format (for `set-storage-format.sh`) |

## License

MIT
