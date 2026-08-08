# One workspace per dbt target, so a full rebuild in one environment can never
# touch another. See docs/ci_architecture.md.

resource "fabric_workspace" "this" {
  for_each = local.environments

  display_name = each.value.display_name
  description  = "dbt accelerator - ${each.key} environment (managed by infra/)."
  capacity_id  = each.value.capacity_id

  lifecycle {
    precondition {
      condition     = (var.capacity_id != null) != (var.capacity_name != null)
      error_message = "Set exactly one of capacity_name or capacity_id. capacity_name is the normal choice; capacity_id only where the principal cannot list capacities."
    }
  }
}

# The dbt service principal's access to each workspace. Skipped for
# environments with dbt_sp_role = null.
resource "fabric_workspace_role_assignment" "dbt_sp" {
  for_each = { for key, env in local.environments : key => env if env.dbt_sp_role != null }

  workspace_id = fabric_workspace.this[each.key].id
  role         = each.value.dbt_sp_role

  principal = {
    id   = var.dbt_service_principal_object_id
    type = "ServicePrincipal"
  }

  lifecycle {
    precondition {
      condition     = var.dbt_service_principal_object_id != null
      error_message = "environments[\"${each.key}\"].dbt_sp_role is set, so dbt_service_principal_object_id must be provided (the SP's OBJECT id, not its client id)."
    }
  }
}
