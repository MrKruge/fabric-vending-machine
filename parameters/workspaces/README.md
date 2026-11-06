# Workspace definitions

Every `*.tfvars` file directly in this folder is merged into the plan by `scripts/merge-workspaces.sh`.
Start by copying a template from `examples/` into this folder under a new name, then edit it:

    cp parameters/workspaces/examples/example-finance.tfvars parameters/workspaces/finance.tfvars

The `examples/` folder is never read, so editing a template in place has no effect.
