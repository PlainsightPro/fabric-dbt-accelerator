# One workspace per dbt target, so a full rebuild in one environment can never
# touch another. See docs/ci_architecture.md.

resource "fabric_workspace" "this" {
  for_each = local.environments

  display_name = each.value.display_name
  description  = "dbt accelerator - ${each.key} environment (managed by infra/)."
  capacity_id  = each.value.capacity_id
}

locals {
  # Blank means "no service principal". Normalised to null once, here, so the
  # rest of the config never has to care which of the two spellings arrived.
  dbt_sp_object_id = trimspace(var.dbt_service_principal_object_id) == "" ? null : trimspace(var.dbt_service_principal_object_id)
}

# The dbt service principal's access to each workspace. Skipped for
# environments with dbt_sp_role = null.
#
# Without these the pipelines authenticate fine and then fail on their first
# query, so a missing object id must be an error rather than a quietly empty
# for_each - that silence is exactly how ci/accept/prod ended up with no access.
resource "fabric_workspace_role_assignment" "dbt_sp" {
  for_each = { for key, env in local.environments : key => env if env.dbt_sp_role != null }

  workspace_id = fabric_workspace.this[each.key].id
  role         = each.value.dbt_sp_role

  principal = {
    id   = local.dbt_sp_object_id
    type = "ServicePrincipal"
  }

  lifecycle {
    precondition {
      condition     = local.dbt_sp_object_id != null
      error_message = "environments[\"${each.key}\"].dbt_sp_role is set, so dbt_service_principal_object_id must be provided (the SP's OBJECT id, not its client id). Leave it blank only if every environment sets dbt_sp_role = null."
    }
  }
}
