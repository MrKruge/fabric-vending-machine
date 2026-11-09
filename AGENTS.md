# AGENTS.md

Guidance for AI coding assistants working in this repository.

## Getting a new user started

Follow `.claude/skills/onboard/SKILL.md`. It is written for any assistant, not only Claude Code: find
out what you can (several `az` accounts are common: confirm the tenant), ask about the rest, run the
read-only preflight, write the tfvars, and run each bootstrap script, push and pull request only after
the user confirms it by name. README "Getting started" is the same procedure for a human: when you
change one, change the other.

## Rules that apply to every change

- **Terraform plan, apply and destroy run only in the pipeline** (Azure DevOps or GitHub Actions).
  Locally you may run `terraform fmt`, `terraform init -backend=false`, `terraform validate` and
  `terraform test`. Nothing else.
- **No click-ops.** Anything missing is fixed in a script, in Terraform or in a pipeline, then re-run.
  The only manual step is a privileged human activating their admin role (PIM) before a bootstrap.
- **No secrets anywhere.** Authentication is workload identity federation. Parameter files hold ids, never secrets.
- **Nothing tenant-specific in this repository.** Real `.tfvars` files belong in the user's own repository,
  never in a change to this one; only `*.tfvars.example` and `parameters/workspaces/examples/` live here.
- **Scripts must be safe to re-run**, also in a tenant with leftovers of an earlier onboarding, and must
  read back what they changed rather than trust an exit code.
- Do not merge pull requests or approve pipeline gates for the user. Show the plan and let them decide.
- Say what was verified and what was not. Offline tests do not prove a live apply works.

## Layout

| Path | What it is |
|---|---|
| `*.tf` (root) | Workspaces, role groups, capacities (one state per environment) |
| `tenant_settings/` | Fabric tenant settings, a separate stack and state |
| `parameters/environments/` | Per-environment values (ids only) |
| `parameters/workspaces/` | One file per logical workspace |
| `parameters/tenant-settings/` | The governed tenant settings |
| `scripts/` | Bootstrap and operational scripts; `capacity.sh` is shared by both CI systems |
| `azure-pipelines*.yml`, `.azuredevops/` | Azure DevOps pipelines |
| `.github/` | GitHub Actions workflows and the shared Terraform action |
| `tests/` | Offline tests (mocked providers, fake `az`) |

## Checks to run before opening a pull request

```bash
terraform fmt -recursive && terraform init -backend=false && terraform validate && terraform test
(cd tenant_settings && terraform init -backend=false && terraform validate && terraform test)
for f in scripts/*.sh tests/*.sh; do bash -n "$f"; done && bash tests/capacity-script.sh && bash tests/merge-workspaces.sh
```
