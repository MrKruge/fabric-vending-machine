---
name: onboard
description: Guides a new user through setting up Fabric Vending in their own Azure and Fabric tenant. Asks a few questions, runs the read-only checks, writes the tfvars, and runs the bootstrap scripts only after confirmation. Use when someone says they want to set this repo up, get started, or onboard.
---

# Onboard to Fabric Vending

You are guiding a person who has just cloned this repo. Your job: ask only what you cannot find out,
do the rest for them, and stop at every step that changes something in their tenant.

## Ground rules

- **Terraform never runs from this machine.** Only the pipeline plans and applies. Offline
  `terraform fmt`, `validate` and `test` are fine. Never run `terraform plan`, `apply` or `destroy`.
- **Everything is code.** If something is missing, fix a script or Terraform, never click in a portal.
  The only manual steps are the two that need a privileged human (see "Admin steps").
- **Confirm before each live change.** Before running a bootstrap script, say exactly what it will
  create and wait for a clear yes naming it. A general "go ahead" earlier does not cover it.
- **Read-only first.** Run `scripts/preflight.ps1` before anything else. It changes nothing.
- Never print tokens or secrets. No secret is needed anywhere in this setup.
- Say what you have verified and what you have not. Do not claim a step worked until its output shows it.

## 1. Find out what you can

Run these yourself and use the answers instead of asking:

- `az account show` for the signed-in account, tenant and default subscription.
- `az account list -o table` for the subscriptions the user can use.
- `git remote -v` to see whether the repo lives on GitHub or Azure DevOps.
- `pwsh --version`, `terraform version` (needs 1.12 or newer), `gh --version` for the platform in use.

If a tool is missing, tell the user the one command that installs it. Do not install anything silently.

## 2. Ask these questions (skip any you already know)

Ask them together, in plain words, with a suggested default for each:

1. **Platform**: GitHub Actions or Azure DevOps? (Default: whatever `git remote -v` shows.)
2. **Subscription** that will hold the state storage and the capacities.
3. **Region** for the capacities and the SKU. Default F2 in a region close to the tenant. Explain that
   F0 only exists in a few regions.
4. **Environments**: the default is `acc` (UAT stage) and `prod`. Offer to rename or add one.
5. **Capacity admin**: an email of a *native member* of the tenant. Guest accounts (`#EXT#`) are rejected.
6. **Admin users**: whose account should be added to the Admin group of every workspace? Ask for
   *every* account they sign in to Fabric with (a guest and a native account are different identities).
7. **Names**: a globally unique storage account name for the Terraform state (3-24 lowercase letters/digits).
8. **Workspaces**: what workspaces do they want first? Offer to copy a file from `parameters/workspaces/examples/`
   into `parameters/workspaces/` under a new name. Only `*.tfvars` files directly in `parameters/workspaces/`
   are merged into the plan; the `examples/` folder is never read, so editing an example in place has no effect
   and a stray example never creates workspaces nobody asked for.

For GitHub also ask for the `owner/name` of the repository. For Azure DevOps, the organization URL,
project and, if the subscription is in another tenant than DevOps, a subscription that sees the
DevOps tenant (`-AzdoAuthSubscriptionId`).

## 3. Preflight (read-only)

```powershell
pwsh scripts/preflight.ps1 -SubscriptionId <sub> -Sku <sku> -Location <region> -AdminEmail <native-admin-email>
```

Explain each `[FAIL]` and its fix. Do not continue past a failure that the user has not resolved.

## 4. Write the configuration (local files only)

- Copy `parameters/environments/prod.tfvars.example` to `<env>.tfvars` for each environment and fill in
  tenant id, capacity name/SKU/region, admin email, subscription. Set `create_domains = true` in the
  first environment only. Put the object ids from question 6 in `workspace_admin_user_object_ids`
  (look them up with `az ad user list --filter "mail eq '...'"` or by UPN).
- Add the workspace tfvars from question 8.
- Run offline checks: `terraform fmt -recursive`, `terraform init -backend=false`, `terraform validate`,
  `terraform test`. Show the result.

## 5. Bootstrap (live changes: confirm each one)

Order matters. For each script, state what it creates, then ask for a yes naming the script.

1. `scripts/bootstrap-backend.ps1` creates the state resource group, storage account and container.
2. `scripts/bootstrap-identity.ps1 -Platform <azuredevops|github>` (Azure DevOps also needs `-AzdoOrganization https://dev.azure.com/<org>`) creates the managed identity and the
   service principal, their Azure roles, Graph permissions, the SPN group, the Fabric Administrator role
   and the Fabric tenant settings the pipeline needs. For Azure DevOps it also wires service connections,
   variable groups, environments, approvals and pipelines. It prints what is left to do.
3. GitHub only: `scripts/bootstrap-github.ps1 -Repository <owner/name> -DryRun` first, show the output,
   then the real run after a yes. It creates federated credentials, repository variables and environments.

Put the service principal object id the identity script prints into `capacity_extra_admins` in each
environment's tfvars (a pull request, not a hand edit on `main`).

## 6. Admin steps only a human can do

The identity script tries them and reports what failed. If it could not:

- **Graph admin consent** for the service principal: a Global or Privileged Role Administrator runs
  `az ad app permission admin-consent --id <appId>`. Needs privileged access to be active (PIM).
- **Fabric Administrator role and Fabric tenant settings** for the service principal: re-run the identity
  script as a Fabric administrator.

If Entra answers "Insufficient privileges", the user's elevation has probably lapsed. Ask them to
re-elevate and re-run; the scripts are idempotent.

## 7. First run

- Open a pull request with the tfvars. The validate and plan builds must pass.
- Merging applies the first environment automatically; later environments wait for approval.
- Never approve for the user. Show them the plan and let them approve.
- Afterwards verify: capacity exists and is paused, workspaces are Active, the user's accounts are in the
  Admin groups. Use read-only commands.

## 8. Tenant settings (optional, later)

`pwsh scripts/get-fabric-tenant-settings.ps1 -TenantId <tenant> -UseAzCli -OutputTfvars` exports the live
settings. Help them choose which to govern and put them in `parameters/tenant-settings/tenant-settings.tfvars`.
The settings the pipeline's service principal depends on cannot be turned off.

## Known gotchas

- Terraform 1.12 or newer is required (Azure DevOps OIDC in the azurerm backend).
- A paused capacity breaks `terraform plan`; the pipeline resumes it first and pauses it afterwards.
- Capacity transitions can take many minutes; do not retry a resume while it is Pausing.
- The Power BI Service principal can be disabled in a tenant (AADSTS500014): a Global Administrator enables it.
- GitHub environments with required reviewers need GitHub Team/Enterprise on a private repository.
- Repositories with immutable OIDC subjects (created after 2026-07-15) need the owner/repo ids in the
  federated credential subject; `bootstrap-github.ps1` reads the right prefix from GitHub.
