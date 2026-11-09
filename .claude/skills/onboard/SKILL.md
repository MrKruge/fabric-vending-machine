---
name: onboard
description: Guides a new user through setting up Fabric Vending in their own Azure and Fabric tenant, on Azure DevOps or GitHub Actions. Finds out what it can, asks the rest, runs the read-only preflight, writes the tfvars, and runs each bootstrap script only after the user confirms it by name. Use when someone says they want to set this repo up, get started, or onboard.
---

# Onboard to Fabric Vending

You are guiding a person who has just cloned this repo. Ask only what you cannot find out, do the
rest for them, and stop before every step that changes something in their tenant or repository.
The README's "Getting started" is the same procedure for a human; keep the two in step.

## Ground rules

- **Terraform never runs from this machine.** Only the pipelines plan and apply. Offline
  `terraform fmt`, and `init -backend=false`, `validate` and `test` in `workspace_vending/` are fine. Never run `terraform plan`,
  `apply` or `destroy`, and never `terraform init` against the real backend.
- **Everything is code.** If something is missing, it is fixed in a script, Terraform or a pipeline and
  re-run, not clicked in a portal. The only human-only step is activating an admin role.
- **Confirm before each live change.** Before a bootstrap script, a project or repository creation, a
  push or a pull request, say exactly what it will create or change and wait for a yes that names it.
  A general "go ahead" earlier does not cover the next step.
- **Read-only first.** `scripts/preflight.ps1` changes nothing; run it before anything else.
- **Never merge a pull request or approve a pipeline gate** for the user. Show the plan and let them do it.
- Never print tokens or secrets. No secret is needed anywhere in this setup.
- Say what you verified and what you did not. A script's exit code is not proof: read the result back.

## 1. Find out what you can

Run these yourself and use the answers instead of asking:

- `az account list --all --query "[].{name:name, id:id, tenant:tenantId, user:user.name}" -o table`:
  every signed-in account and its subscriptions. Several accounts are common, and the default one is
  often not the one for the Fabric tenant. Do not assume `az account show` is the target.
- `git remote -v`: whether the clone came from GitHub (the public repo) and whether the user already
  added their own remote.
- `pwsh --version`, `az version`, `terraform version` (1.12 or newer), `git --version`, and `gh --version`
  plus `gh auth status` for GitHub, or `az extension show --name azure-devops` for Azure DevOps.

If a tool is missing, give the one install command from the README's tools table and wait. Do not
install anything silently. `pwsh` failing with "Couldn't find a valid ICU package" in a container:
install `libicu`, or run it with `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`.

## 2. Ask these questions (skip any you already know)

Ask them together, in plain words, with a suggested default for each:

1. **Tenant first**: which Entra tenant should Fabric Vending manage? Then the **subscription** in it
   for the state storage and the capacities. If the subscription they name is not in the `az` list, the
   portal is using another account: ask them to `az login --tenant <tenant-id>` with that account. A
   subscription created minutes ago can take a while to appear.
2. **Platform**: Azure DevOps or GitHub Actions.
   - Azure DevOps: the organisation URL and project name. Ask whether the project exists; if not, it is
     created in step 5a. If the organisation is connected to a different Entra tenant than the
     subscription, a subscription in the organisation's tenant for `-AzdoAuthSubscriptionId` (see 5a).
   - GitHub: the `owner/name` of the user's own repository (not the public Fabric Vending repo), and
     whether it exists yet.
3. **Region and SKU**: default F2 in a region close to the tenant. F0 exists in very few regions.
4. **Environments**: default `acc` (UAT stage) and `prod`. DEV is an extra (README: "Adding a DEV
   environment").
5. **Capacity admin**: the UPN of a *native member* of the tenant, for example
   `admin@<tenant>.onmicrosoft.com`. Guests are rejected, and so is a member whose UPN contains `#EXT#`
   (a tenant created with a personal Microsoft account shows its creator that way). Preflight checks it.
6. **Workspace admins**: *every* account they sign in to Fabric with (native, guest and personal
   accounts are different identities). You look up their object ids.
7. **State storage name**: globally unique, 3-24 lowercase letters and digits.
8. **Workspaces** to start with, and their domains. Copy a template from
   `parameters/workspaces/examples/` into `parameters/workspaces/<name>.tfvars`; only files directly in
   `parameters/workspaces/` are deployed. Every `data_domain` becomes a domain automatically.

The bootstrap needs Global Administrator (or Privileged Role Administrator and Fabric Administrator).
Ask the user to activate the role in PIM before step 5, and again if a script reports "Insufficient
privileges" later: activations expire.

## 3. Preflight (read-only)

```powershell
pwsh scripts/preflight.ps1 -SubscriptionId <sub> -Location <region> -Sku <sku> -AdminEmail <upn>[,<upn>]
```

It prints the account and tenant in use: confirm with the user that this is the right tenant. Explain
each `[FAIL]` and its fix, and do not continue past one the user has not resolved. `[todo]
Microsoft.Fabric not registered` is fine (bootstrap-identity registers it). If the directory cannot be
read, the user is a guest there or their role is not activated: ask them to fix that, you cannot look
up the accounts you need otherwise. Use the UPN preflight reports in `capacity_admin_email`, not the
mail address (some accounts have none).

## 4. Write the configuration (local files only)

- Copy `parameters/environments/acc.tfvars.example` and `prod.tfvars.example` to `.tfvars` and fill in
  the tenant id, subscription id, capacity name/SKU/region (the region also goes to `-Location` in
  every script), and the capacity admin UPN. `create_domains = true` only in `acc`.
- Look up the object ids for question 6 (`az ad user show --id <upn> --query id -o tsv`) and put them in
  `workspace_admin_user_object_ids` in both files.
- Leave `capacity_extra_admins` until bootstrap-identity has printed the service principal object id.
- Add the workspace files from question 8.
- Run and show: `terraform fmt -recursive && (cd workspace_vending && terraform init -backend=false && terraform validate && terraform test)`.

## 5. Bootstrap (live changes: confirm each one by name)

1. `scripts/bootstrap-backend.ps1 -SubscriptionId <sub> -Location <region> -StorageAccountName <name>`:
   state resource group, storage account (Entra-only access), container, a data role for the user.

### 5a. Azure DevOps

2. If the project does not exist: `az devops project create --organization <org-url> --name "<project>"
   --visibility private` (it gets an empty repository with the same name).
3. Push the code to it: `git remote add azdo <org-url>/<project>/_git/<repo>` then `git push azdo main`.
   Safe: nothing runs until the pipelines exist. Never push to the public GitHub origin.
4. `scripts/bootstrap-identity.ps1 -SubscriptionId <sub> -Location <region> -StateResourceGroup
   rg-fabricvending-tfstate -StorageAccountName <name> -AzdoOrganization <org-url> -AzdoProject
   "<project>" [-RepoName <repo>] [-AzdoAuthSubscriptionId <sub in the organisation's tenant>]`.
   `-AzdoAuthSubscriptionId` only fetches a DevOps token; nothing is created in it. The organisation's
   tenant is under Organization settings > Microsoft Entra in Azure DevOps.

### 5b. GitHub Actions

2. `gh` must be signed in where you run, with the `workflow` scope: `gh auth login -s workflow` or
   `gh auth refresh -s workflow`. A login on another machine or outside a container does not count.
3. If the repository does not exist: `gh repo create <owner>/<repo> --private`. Push the code to it
   (`git remote add github https://github.com/<owner>/<repo>.git`, `git push github main`). Safe: the
   workflows skip until the environment tfvars exist. Never push to the public Fabric Vending repo.
4. `scripts/bootstrap-identity.ps1 -Platform github -SubscriptionId <sub> -Location <region>
   -StateResourceGroup rg-fabricvending-tfstate -StorageAccountName <name>`.
5. `scripts/bootstrap-github.ps1 -SubscriptionId <sub> -StateResourceGroup rg-fabricvending-tfstate
   -StorageAccountName <name> -Repository <owner>/<repo> -ReviewerLogin <login> -DryRun`, show the
   output, then the real run after a yes. Read its "Approval gates" lines to the user: without a
   reviewer (private repository on GitHub Free) a merge applies acc and prod with nobody approving.

### After the identity script

Read its last lines. Anything under "Not done yet" blocks the first deploy: ask the user to activate the
role it names and re-run the script (it is idempotent). Then verify read-only that the service principal
has both Graph app role assignments and the Fabric Administrator role, and that the three tenant
settings list `grp-fabricvending-spns`.

Put the printed service principal object id in `capacity_extra_admins` in every environment file.

## 6. First deploy

- Commit the tfvars and workspace files on a branch, push to the user's remote, open a pull request
  (after a yes). `validate` and a plan per environment must pass. Show the plan summaries.
- On a pull request prod is planned beside acc, so a domain acc will create is not assigned in prod's
  plan yet. After the merge prod is planned after acc applied and gets it. Say so if the user asks.
- The user merges. Never merge or approve for them. Watch the run and report.
- Azure DevOps: a build queued by hand does not satisfy the pull request's build policy. After a fix,
  push a commit or `az repos pr policy queue --id <pr> --evaluation-id <id>` (ids from
  `az repos pr policy list --id <pr>`).
- Afterwards verify, read-only: both capacities exist and are paused, workspaces are Active with their
  domain, and the user's accounts are in the Admin groups.

## 7. Tenant settings (optional, later)

`pwsh scripts/get-fabric-tenant-settings.ps1 -TenantId <tenant> -UseAzCli -OutputTfvars` exports the live
settings. Help them choose which to govern and put them in `parameters/tenant-settings/tenant-settings.tfvars`
(from the `.example`). The tenant-settings pipeline does nothing until that file exists. The settings the
pipeline's service principal depends on cannot be turned off.

## Known gotchas

- Domains are protected from deletion. If a domain's last workspace is removed or its `data_domain`
  renamed, the acc plan fails ("Instance cannot be destroyed"): keep the old name in `domains` in
  `acc.tfvars`. When adding a DEV environment, acc keeps `create_domains = true`; dev gets `false`.

- `AADSTS700213: No matching federated identity record` on the first plan: a federated credential from an
  earlier onboarding had the same name and another subject. Re-run bootstrap-identity (Azure DevOps) or
  bootstrap-github; they replace it now.
- Tenant settings that still name a deleted group (earlier onboarding cleaned up) are repaired by
  bootstrap-identity; it prints which group it dropped.
- A paused capacity breaks `terraform plan`; the pipeline resumes it first and pauses it afterwards.
  Capacity transitions can take minutes; do not resume while it is Pausing.
- The Power BI Service principal can be disabled in a tenant (AADSTS500014): a Global Administrator enables it.
- GitHub required reviewers need a public repository, or GitHub Team/Enterprise for a private one.
- GitHub repositories created after 2026-07-15 use immutable OIDC subjects (owner and repository ids);
  `bootstrap-github.ps1` reads the right prefix from GitHub.
