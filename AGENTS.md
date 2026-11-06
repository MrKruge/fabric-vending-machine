# AGENTS.md

Guidance for AI coding assistants working in this repository.

## Getting a new user started

Follow `.claude/skills/onboard/SKILL.md`. It is written for any assistant, not only Claude Code: find
out what you can, ask about eight things, run the read-only preflight, write the tfvars, and run the
bootstrap scripts only after the user confirms each one by name.

## Rules that apply to every change

- **Terraform plan, apply and destroy run only in the pipeline** (Azure DevOps or GitHub Actions).
  Locally you may run `terraform fmt`, `terraform init -backend=false`, `terraform validate` and
  `terraform test`. Nothing else.
- **No click-ops.** Anything missing is fixed in a script, in Terraform or in a pipeline, then re-run.
  The only manual steps are Graph admin consent and the Fabric Administrator role, which need a
  privileged human.
- **No secrets anywhere.** Authentication is workload identity federation. Parameter files hold ids, never secrets.
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
for f in scripts/*.sh tests/*.sh; do bash -n "$f"; done && bash tests/capacity-script.sh
```
