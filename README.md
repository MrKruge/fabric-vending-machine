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
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

Terraform for automating Microsoft Fabric workspace provisioning. It is fully parameterized, with no hardcoded tenant values: drop in your own `.tfvars` files and it works against any Fabric tenant.

## How it runs

Terraform never runs from a laptop. Two one-time bootstrap scripts prepare the identities, then three pipelines do everything else:

| Pipeline | What it does | Triggers |
|---|---|---|
| `fabricvending-validate` | Offline checks: format, validate, mocked-provider tests for both stacks, shell syntax. | Every PR (required build policy). |
| `fabricvending-deploy` | Workspaces, role groups, capacities. Plans acc and prod, applies acc, then prod after an approval. | PR plan, then push to `main`. |
| `fabricvending-tenant-settings` | Tenant-wide Fabric settings in their own stack and state, behind their own approval. | Only when the settings or the stack change. |

Each pipeline authenticates with workload identity federation, so no secret exists anywhere: a user-assigned managed identity for Azure and a service principal for the Fabric and Graph APIs. Capacities are resumed before a plan or apply and paused again afterwards, so they only run while Terraform works.

**Status:** proven end to end on Azure DevOps against a real tenant (workspaces, groups, capacities, 174 tenant settings). GitHub Actions workflows and an AI-guided onboarding (`/onboard`) are in the repo; the GitHub path has not run live yet.

## What it provisions

For each workspace entry you define:

- A **Fabric workspace** (optionally assigned to a capacity)
- **4 AAD security groups** (`Admin`, `Contributor`, `Viewer`, `Member`) following a consistent naming convention
- **Fabric workspace role assignments** linking those groups to the workspace
- Optional **Git integration** (Azure DevOps or GitHub) on DEV workspaces
- Optional **Fabric domain assignment**
- Optional **owner group nesting** (e.g. a central "Fabric Admins" group)
- Optional **deployment SPN admin** grant for CI/CD pipelines

Domains are tenant-wide resources. The module creates them in your first/DEV stage and looks them up by name in subsequent stages — no hardcoded IDs required.

## Architecture

```
Fabric Tenant
├── Capacity
│   ├── Workspace: Finance DEV  ──── Domain: Finance
│   │   ├── AAD Group: FABRIC_WORKSPACE_FINANCE_DEV_ADMIN
│   │   ├── AAD Group: FABRIC_WORKSPACE_FINANCE_DEV_CONTRIBUTOR
│   │   ├── AAD Group: FABRIC_WORKSPACE_FINANCE_DEV_VIEWER
│   │   └── AAD Group: FABRIC_WORKSPACE_FINANCE_DEV_MEMBER
│   ├── Workspace: Sales DEV    ──── Domain: Sales
│   └── ...
├── Workspace: Finance UAT
├── Workspace: Finance          ──── (PROD — no suffix)
└── ...
```

## Getting started

The quickest way is to let your AI assistant do the typing: open the repo in Claude Code and run `/onboard`
(other assistants: point them at [AGENTS.md](AGENTS.md)). It asks about eight things, runs the read-only checks,
writes your tfvars and runs the bootstrap scripts, each only after you confirm it. The manual path is below.

| Step | Azure DevOps | GitHub Actions |
|---|---|---|
| 1. State storage | `scripts/bootstrap-backend.ps1` | `scripts/bootstrap-backend.ps1` |
| 2. Identities and permissions | `scripts/bootstrap-identity.ps1 -AzdoOrganization https://dev.azure.com/<org> ...` | `scripts/bootstrap-identity.ps1 -Platform github` |
| 3. Wire the CI system | done by step 2 (service connections, variable groups, pipelines, approvals) | `scripts/bootstrap-github.ps1 -Repository <owner/name>` (try `-DryRun` first) |
| 4. Two admin steps | Graph admin consent, Fabric Administrator role (the scripts tell you if they could not do it) | same |

The Azure DevOps path has run against a real tenant. The GitHub workflows (`.github/workflows/`) are written
against the provider and GitHub documentation and pass offline checks, but they have not run live yet.

## Prerequisites

1. A **Microsoft Fabric capacity** (F SKU or P SKU)
2. A **Service Principal** with:
   - `Fabric Administrator` or capacity/workspace admin rights in Fabric
   - `Groups.ReadWrite.All` and `Directory.ReadWrite.All` in Azure AD
3. **Terraform >= 1.12.0** (the azurerm backend only supports Azure DevOps OIDC from 1.12)
4. **Fabric provider >= 1.11** — uses `microsoft/fabric`

## Quick start

### 1. Clone and initialize

```bash
git clone https://<your-org>@dev.azure.com/<your-org>/Fabric%20Vending/_git/Fabric%20Vending
cd "Fabric Vending"
terraform init
```

### 2. Configure your backend

For local testing you can skip this step and use the default local backend.

For a real deployment, provision an Azure Storage Account for state first:

```powershell
.\scripts\bootstrap-backend.ps1 `
    -SubscriptionId "00000000-0000-0000-0000-000000000000" `
    -StorageAccountName "stfabricvendingtf001"
```

The script writes `backend.generated.tf` (gitignored) for you, then run `terraform init -reconfigure`.

#### F0 capacity (flag: `capacity_sku = "F0"`)

The `azurerm` provider only accepts `F2` and up. For anything else Azure offers (for example `F0`, available in a few regions), create the capacity through ARM and let Terraform look it up by name:

```powershell
.\scripts\bootstrap-capacity.ps1 `
    -SubscriptionId "00000000-0000-0000-0000-000000000000" `
    -CapacityName "fabvendingdemo" -Sku F0 -Location westcentralus `
    -AdminEmail "you@example.com"
```

It registers `Microsoft.Fabric`, creates the capacity and pauses it (use `-LeaveRunning` to skip the pause). Then set `create_capacity = true`, `capacity_sku = "F0"` and `capacity_name = "fabvendingdemo"` in your tfvars: Terraform skips creating the capacity and looks the script-created one up by name. For every other SKU (F2 and up) leave the script out and let Terraform create the capacity (`create_capacity = true`). Alternatively, point at any existing capacity with `fabric_capacity_name`. Resume a paused capacity before applying anything that touches workspace content.

### Deploying through the pipeline (the intended path)

Terraform builds all infrastructure, including the Fabric capacities, and runs only in Azure Pipelines (`azure-pipelines.yml`): every pull request gets a plan per environment (build-validation policies on `main`), and a push to `main` plans and applies `acc`, then `prod` behind an approval on the `fabricvending-prod` environment. The pipeline resumes the capacity before an apply and pauses it afterwards.

Bootstrap only prepares what Terraform and the pipeline need to start. You run these by hand, once:

1. `scripts/preflight.ps1`: read-only checks for the common first-run blockers
2. `scripts/bootstrap-backend.ps1`: resource group + storage account for Terraform state
3. Push the code to the Azure DevOps repo (the pipelines need `azure-pipelines.yml` to exist)
4. `scripts/bootstrap-identity.ps1`: the two identities and their permissions, the empty capacity resource group, and per environment (`acc`, `prod`) the service connections, variable group and pipeline environment, plus the pipelines and PR policies

`scripts/bootstrap-capacity.ps1` is only for SKUs the azurerm provider rejects (F0); for F2 and up leave it out and let Terraform create the capacity (`create_capacity = true` in `parameters/environments/<env>.tfvars`).

Environments live in `parameters/environments/<env>.tfvars` (IDs only, never secrets): `acc` maps to the `UAT` stage and `prod` to `PROD`. After the identity script runs, put the service principal object id it prints into `capacity_extra_admins` so the pipeline can assign workspaces to the capacity.

Two identities, each only as powerful as it needs to be:

| Identity | Used for | Why |
|---|---|---|
| User-assigned **managed identity** | State storage, capacity create/pause/resume (everything in Azure) | Roles are plain Azure RBAC |
| **Service principal** (app registration) | Fabric and Microsoft Graph APIs (workspaces, roles, groups) | These APIs cannot use a managed identity from a pipeline |

Then commit `parameters/environments/<env>.tfvars` (IDs only, never secrets) and your workspace definitions. Two things cannot be scripted: Entra admin consent for the Graph permissions (needs a Global or Privileged Role Administrator), and the Fabric tenant setting "Service principals can use Fabric APIs" (needs a Fabric administrator). The identity script prints exactly what is still missing.

### 3. Configure authentication

Three options — pick one:

**Option A — OIDC / Workload Identity Federation (recommended for CI/CD, no secret)**

The shipped pipeline already does this: `.azuredevops/steps/terraform.yml` passes the pipeline's OIDC token and the IDs of two Azure DevOps service connections (workload identity federation). `providers.tf` binds `azurerm` to the managed identity (`azure_client_id`, `azure_service_connection_id`) and `azuread`/`fabric` to the service principal (`fabric_spn_client_id`, `fabric_service_connection_id`). Leave `fabric_spn_client_secret` unset. For a single-identity setup, set only `fabric_spn_client_id` and `azurerm` uses it too.

---

**Option B — Client secret (if OIDC is not available)**

Store the secret in **Azure Key Vault** (Azure DevOps variable group) or a pipeline secret variable — never in pipeline YAML or tfvars files. Inject at runtime:

```bash
export TF_VAR_fabric_spn_client_id="<your-spn-client-id>"
export TF_VAR_fabric_spn_client_secret="<from-key-vault-or-pipeline-secret>"
```

---

**Option C — Azure CLI (local dev only)**

```bash
az login
# Leave both SPN variables unset — the provider falls back to your CLI session.
```

### 4. Create your environment tfvars

Copy the example and fill in your values:

```bash
cp parameters/environments/dev.tfvars.example parameters/environments/dev.tfvars
# edit dev.tfvars with your tenant ID, capacity ID, etc.
```

### 5. Create your workspace parameter files

Copy an example workspace file:

```bash
cp parameters/workspaces/examples/example-finance.tfvars parameters/workspaces/my-workspace.tfvars
# edit with your workspace name and domain
```

### 6. Plan and apply

Merge all workspace files together using `-var-file` flags:

```bash
terraform plan \
  -var-file="parameters/environments/dev.tfvars" \
  -var-file="parameters/workspaces/my-workspace.tfvars"

terraform apply \
  -var-file="parameters/environments/dev.tfvars" \
  -var-file="parameters/workspaces/my-workspace.tfvars"
```

For multiple workspaces, add more `-var-file` arguments — Terraform merges maps automatically:

```bash
terraform apply \
  -var-file="parameters/environments/dev.tfvars" \
  -var-file="parameters/workspaces/finance.tfvars" \
  -var-file="parameters/workspaces/sales.tfvars" \
  -var-file="parameters/workspaces/operations.tfvars"
```

## Prerequisites and gotchas

Run `scripts/preflight.ps1` first. It changes nothing and checks the first four items below. These are the things that tripped up real first runs:

- **Power BI Service disabled in the tenant.** Fabric API sign-ins fail with `AADSTS500014 ... service principal for resource ... is disabled`. A Global Administrator enables it: Entra > Enterprise applications > Power BI Service > Properties > "Enabled for users to sign-in" = Yes.
- **Capacity admin cannot be a guest.** The `#` in a guest UPN (`name_domain.com#EXT#@tenant.onmicrosoft.com`) gives `Invalid principal name`, and the guest's object ID gives `All provided principals must be existing, user or service principals`. Use a native member account, or ask a tenant admin to remove `#EXT#` from the guest's UPN.
- **`Microsoft.Fabric` must be registered** on the subscription. `bootstrap-identity.ps1` does it, because the pipeline identity has no subscription-level rights and the azurerm provider is set not to auto-register providers (`resource_provider_registrations = "none"`).
- **Capacity region.** The region must suit the tenant's geography, and a busy region can be full; pick another in the same geography. `Location needs to match the PowerBI cluster location` means the region is wrong for the tenant. Check availability per SKU: `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Fabric/skus?api-version=2023-11-01"`.
- **F0 is rare.** It is only offered in West Central US and two canary regions, so it needs a tenant with a US home region. Everywhere else the smallest SKU is F2.
- **Fabric API calls from the CLI need MFA.** For ad hoc reads use `az login --tenant <tenant> --scope https://api.fabric.microsoft.com/.default`.
- **Azure CLI cannot edit PIM eligibility** (`AADSTS65002`); do that part in the Entra portal.
- **Fabric tenant settings gate the API, not only roles.** Even with the Fabric Administrator role, the service principal gets `InsufficientScopes` unless `AllowServicePrincipalsUseReadAdminAPIs`, `AllowServicePrincipalsUseWriteAdminAPIs` and `ServicePrincipalAccessGlobalAPIs` are enabled for it. `bootstrap-identity.ps1` enables them for the SPN security group; the tenant settings stack refuses to turn them off.
- **Graph admin consent and the Fabric Administrator role need a privileged admin.** Run `bootstrap-identity.ps1` while elevated (Global Administrator or Privileged Role Administrator). Otherwise it prints the one command to run later, and the first apply fails when it creates the Entra groups.
- **Keeping a capacity running.** The pipeline pauses the capacity after every apply. For an event or a demo set `capacity_keep_running = true` in that environment's tfvars through a pull request, and set it back to `false` afterwards (a running capacity is billed). The flag is read by `scripts/capacity.sh`.
- **Terraform 1.12 or newer.** The azurerm backend only supports Azure DevOps OIDC from 1.12.0.
- **First plan of a later environment.** Domains are created by the first environment (`create_domains = true`) and looked up by name in the others. Until that environment has applied, the lookup finds nothing and domain assignments are skipped; the next plan picks them up.
- **Azure DevOps in another tenant than the subscription.** Get the DevOps token through a subscription visible in the organisation's tenant (`-AzdoAuthSubscriptionId` on `bootstrap-identity.ps1`). Do not pass `--tenant` to `az account get-access-token`; it can fall back to a different signed-in account.

## File structure

```
FabricVending/
├── terraform.tf                          # required_providers
├── providers.tf                          # azuread + fabric provider config
├── backend.tf                            # state backend (configure before use)
├── variables.tf                          # all input variables
├── main.tf                               # data sources
├── locals.tf                             # filtering and naming logic
├── workspace.tf                          # workspaces, groups, role assignments
├── domains.tf                            # domain create/lookup
├── outputs.tf                            # workspace IDs, group IDs, etc.
├── .gitignore
├── azure-pipelines.yml                   # workspaces: plan on PR, apply acc then prod on main
├── azure-pipelines-validate.yml          # offline checks, build policy on main
├── azure-pipelines-tenant-settings.yml   # tenant settings: own trigger, own approval
├── .github/                              # GitHub Actions workflows and the shared Terraform action
├── AGENTS.md                             # guidance for AI assistants
├── .claude/skills/onboard/               # the /onboard skill
├── tenant_settings/                      # separate Terraform stack and state for tenant settings
├── tests/                                # offline terraform tests (mocked providers)
├── parameters/
│   ├── environments/
│   │   ├── dev.tfvars.example            # DEV stage values (copy → dev.tfvars)
│   │   ├── uat.tfvars.example
│   │   └── prod.tfvars.example
│   ├── tenant-settings/
│   │   └── tenant-settings.tfvars        # governed Fabric tenant settings
│   └── workspaces/
│       ├── examples/                     # templates: never read by merge-workspaces.sh, copy don't edit in place
│       │   ├── example-finance.tfvars
│       │   ├── example-sales.tfvars
│       │   └── example-poc-prod-only.tfvars
│       └── <name>.tfvars                 # one file per logical workspace; these are what the pipeline plans
└── scripts/
    ├── bootstrap-backend.ps1              # one-time Azure Storage Account setup for TF state
    ├── bootstrap-capacity.ps1             # register Microsoft.Fabric, create + pause a capacity (supports F0)
    ├── check-alignment.ps1                # drift detection: expected vs actual groups/role assignments
    ├── check-storage-format.sh            # inspect/set dataset storage format for one workspace
    ├── set-storage-format.sh              # bulk-reconcile storage format from TF state (CI/CD)
    ├── merge-workspaces.sh                # flatten parameters/workspaces/*.tfvars into one map
    ├── bootstrap-identity.ps1             # identities, Azure DevOps wiring (-Platform), tenant settings the SPN needs
    ├── bootstrap-github.ps1               # GitHub Actions wiring: federated credentials, variables, environments
    ├── capacity.sh                        # resume/suspend a capacity (used by both CI systems)
    ├── preflight.ps1                      # read-only checks before the first run
    └── get-fabric-tenant-settings.ps1     # pull tenant-wide Fabric admin settings into tfvars
```

## Variables reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `tenant_id` | yes | — | Azure AD tenant ID |
| `fabric_capacity_id` | no | `null` | Fabric capacity GUID (not the ARM resource ID) |
| `fabric_capacity_name` | no | `null` | Capacity display name; Terraform looks up the GUID. Use with `bootstrap-capacity.ps1` |
| `workspace_environment_suffix` | yes | — | `DEV`, `UAT`, or `PROD` |
| `workspaces` | yes | — | Map of workspace definitions (see below) |
| `domains` | no | `[]` | List of domain names to create/look up |
| `create_domains` | no | `false` | `true` in first stage, `false` thereafter |
| `group_prefix` | no | `FABRIC_WORKSPACE` | Prefix for AAD group names |
| `owner_group_display_name` | no | `null` | Existing AAD group to nest into each workspace |
| `deployment_spn_object_id` | no | `null` | SPN to grant Admin on all workspaces |
| `git_connection_id` | no | `null` | Fabric Git connection ID (required if using Git integration) |
| `fabric_spn_client_id` | no | `null` | SPN client ID — required for OIDC or secret auth; omit for Azure CLI |
| `fabric_spn_client_secret` | no | `null` | SPN client secret — omit to use OIDC (pipeline) or Azure CLI (local) |

### Workspace object schema

```hcl
workspaces = {
  finance_DEV = {
    display_name           = "Finance"        # workspace display name (env suffix added automatically)
    data_domain            = "Finance"        # must match a name in var.domains
    environment            = "DEV"            # DEV, UAT, or PROD
    git_integration        = true             # optional, default false
    git_provider_type      = "AzureDevOps"   # or "GitHub"
    git_organization_name  = "your-org"
    git_project_name       = "Your Project"  # AzureDevOps only
    git_repository_name    = "your-repo"
    git_branch_name        = "main"           # optional, default "main"
    git_directory_name     = "/workspaces/Finance"  # optional, default "/"
    default_storage_format = "Large"          # optional, Large or Small
    assign_capacity        = true             # optional, default true
  }
}
```

## AAD group naming convention

Groups are named: `<group_prefix>_<WORKSPACE_NAME>_<ENV>_<ROLE>`

| Environment | Example |
|---|---|
| DEV | `FABRIC_WORKSPACE_FINANCE_DEV_ADMIN` |
| UAT | `FABRIC_WORKSPACE_FINANCE_UAT_CONTRIBUTOR` |
| PROD | `FABRIC_WORKSPACE_FINANCE_VIEWER` (no suffix) |

Change the prefix using the `group_prefix` variable.

## Multi-stage deployment

The module uses a single state per environment stage. Run `terraform apply` three times — once per stage — with the matching environment tfvars file. Domains are created in DEV (`create_domains = true`) and looked up by name in UAT and PROD.

## Tenant settings

Fabric tenant settings are tenant-wide, so they live in their own Terraform stack (`tenant_settings/`), their own state and their own pipeline (`azure-pipelines-tenant-settings.yml`). The pipeline runs only when `parameters/tenant-settings/` or the stack changes, so editing a setting does not plan the workspaces and the other way round. A pull request gets a plan; a push to `main` plans, then waits for approval on the `fabricvending-global` environment before it applies. That environment, its service connections and its variable group form a tenant-wide `global` scope, independent of acc and prod.

Start from the live tenant and keep only what you want governed:

```powershell
az login --tenant <tenant-id>
pwsh scripts/get-fabric-tenant-settings.ps1 -TenantId <tenant-id> -UseAzCli -OutputTfvars
```

That writes every setting as a `fabric_tenant_settings` map. Copy the entries you want into `parameters/tenant-settings/tenant-settings.tfvars`. Settings that are not listed are left alone, and removing an entry stops managing it without resetting it. `delegated_to` lists Entra group display names; empty means the whole tenant.

The three settings the pipeline's own service principal depends on cannot be disabled here: the plan refuses it.

## Drift detection

Use `scripts/check-alignment.ps1` to verify that expected workspaces and AAD groups exist in your tenant and that role assignments are correct:

```powershell
Connect-AzAccount
.\scripts\check-alignment.ps1 -GroupPrefix "FABRIC_WORKSPACE" -WorkspaceNames @("Finance","Sales")
```

This is the tool's answer to ClickOps drift: anyone can add a role assignment by hand in the
Fabric portal, but `check-alignment.ps1` flags it immediately — it diffs *actual* role
assignments against the naming convention this module enforces, not just whether the
Terraform-managed resources exist.

## Other scripts

| Script | Why | Usage |
|---|---|---|
| `scripts/check-storage-format.sh` | The Fabric/Terraform provider doesn't manage per-dataset storage format (Large/Small) — it's a Power BI REST API setting. Use this to inspect or fix one workspace at a time, e.g. from Cloud Shell with no SPN needed. | `bash scripts/check-storage-format.sh <workspace_id> [--set-large\|--set-small]` |
| `scripts/set-storage-format.sh` | Bulk version of the above — reads `workspace_storage_formats` straight from Terraform state/plan and reconciles every vended workspace (and optionally every dataset in them) to its configured `default_storage_format`. Built for CI/CD, run right after `terraform apply`. | `bash scripts/set-storage-format.sh <tf_working_dir> [--dry-run] [--datasets]` |
| `scripts/merge-workspaces.sh` | `-var-file` flags get unwieldy once you have more than a handful of workspace tfvars files. This flattens every file in `parameters/workspaces/` into one `workspaces = { ... }` map so `terraform plan`/`apply` only needs one `-var-file`. | `bash scripts/merge-workspaces.sh parameters/workspaces > merged_workspaces.auto.tfvars` |
| `scripts/get-fabric-tenant-settings.ps1` | Fabric tenant-wide admin settings (e.g. `PublishToWeb`, external sharing) are tenant-wide ClickOps targets — one person can flip a tenant setting from the portal with no review. This pulls current settings into a ready-to-paste tfvars block, and `-CheckPublishToWeb` audits which reports are currently publicly exposed before you lock that setting down. | `./scripts/get-fabric-tenant-settings.ps1 -TenantId <tenant-id> [-UseAzCli] [-OutputTfvars] [-CheckPublishToWeb]` |

## Outputs

| Output | Description |
|---|---|
| `workspace_ids` | Map of workspace key → Fabric workspace ID |
| `domain_ids` | Map of domain name → Fabric domain ID |
| `aad_group_object_ids` | Map of workspace_role key → AAD group object ID |
| `workspace_storage_formats` | Map of workspace ID → storage format (for post-apply config) |

## License

MIT

> **OPEN-SOURCE COPY.** Environment files are examples. Copy `parameters/environments/*.tfvars.example` to `*.tfvars` and `parameters/tenant-settings/tenant-settings.tfvars.example` to `tenant-settings.tfvars`, then fill them in. The pipelines read those files, so commit them to your own repository (they hold ids, never secrets).
