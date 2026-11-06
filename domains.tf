# ── Data Domains ──────────────────────────────────────────────────────────────
# Domains are tenant-wide resources.
# Set create_domains = true in your first/DEV stage to create them.
# All subsequent stages set create_domains = false and look up existing domains by name.

resource "fabric_domain" "this" {
  for_each = var.create_domains ? toset(var.domains) : toset([])

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

  # Domains not created yet (e.g. prod planned before acc has applied) are left out; workspace.tf
  # skips domain assignment for them.
  domain_ids = var.create_domains ? (
    { for k, v in fabric_domain.this : k => v.id }
    ) : (
    { for d in var.domains : d => local.existing_domain_ids[d] if contains(keys(local.existing_domain_ids), d) }
  )
}
