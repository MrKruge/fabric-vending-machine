# Contributing

Thanks for helping. Issues and pull requests are both welcome.

## How

1. **Fork** the repository and create a branch in your fork.
2. Make **one change per pull request**: a fix, a feature, or a docs update. Smaller is faster to review.
3. Run the offline checks (below) and make sure they pass.
4. Open a pull request against `main` and say what it changes and how you checked it.

The maintainer reviews and merges. Workflows on a pull request from a fork start after the maintainer
approves them, and they run without secrets: nothing in this repository can reach a tenant.

## Offline checks

Nothing here needs Azure or a Fabric tenant:

```bash
terraform fmt -recursive && (cd workspace_vending && terraform init -backend=false && terraform validate && terraform test)
(cd tenant_settings && terraform init -backend=false && terraform validate && terraform test)
for f in scripts/*.sh tests/*.sh; do bash -n "$f"; done && bash tests/capacity-script.sh && bash tests/merge-workspaces.sh
```

PowerShell scripts must parse (`validate` checks it) and stay safe to re-run.

## Rules

- **Never commit real values.** No tenant, subscription or object ids, user names, email addresses or
  resource names from a real tenant. Only `*.tfvars.example` files and `parameters/workspaces/examples/`
  belong here; your own `.tfvars` live in your own repository.
- **No secrets, ever.** Authentication is workload identity federation; nothing needs a key or password.
- **Terraform plan and apply run only in the pipelines.** Tests use mocked providers.
- **Keep the human and the AI path in step.** A change to the onboarding steps updates both README
  "Getting started" and `.claude/skills/onboard/SKILL.md`.
- **Both platforms.** A pipeline change usually needs the same change for Azure DevOps
  (`azure-pipelines*.yml`, `.azuredevops/`) and GitHub Actions (`.github/`).

## Reporting a problem

Open an issue with what you ran, what you expected and what happened. Remove ids and names from any
output you paste.

By contributing you agree that your contribution is licensed under the MIT License of this repository.
