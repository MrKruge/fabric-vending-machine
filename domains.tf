# ── Data Domains ──────────────────────────────────────────────────────────────
# Domains are tenant-wide resources. Every workspace's `data_domain` is a domain, so there is
# nothing else to list: var.domains only adds domains that no workspace uses (yet).
# The first environment to deploy (create_domains = true) creates them; every later environment
# (create_domains = false) looks them up by name.

locals {
  all_domains = toset(distinct(concat(
    var.domains,
    [for ws in values(var.workspaces) : ws.data_domain if ws.data_domain != ""],
  )))
}

resource "fabric_domain" "this" {
  for_each = var.create_domains ? local.all_domains : toset([])

  display_name = each.key

  lifecycle {
    prevent_destroy = true
  }
}

data "fabric_domains" "all" {
  count = var.create_domains ? 0 : 1
}

locals {
  existing_domain_ids = var.create_domains ? {} : {
    for x in data.fabric_domains.all[0].values : x.display_name => x.id
  }

  # A domain that does not exist yet is left out and workspace.tf skips its assignment. The pipelines
  # plan a later environment only after the first one has applied, so this only happens when a later
  # environment is planned on its own (a pull request) before the domain has ever been created.
  domain_ids = var.create_domains ? (
    { for k, v in fabric_domain.this : k => v.id }
    ) : (
    { for d in local.all_domains : d => local.existing_domain_ids[d] if contains(keys(local.existing_domain_ids), d) }
  )
}
