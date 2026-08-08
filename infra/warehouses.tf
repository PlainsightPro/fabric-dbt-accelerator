# The dbt build target of each environment: DBT_FABRIC_DATABASE is its display
# name, DBT_FABRIC_HOST its connection_string.

resource "fabric_warehouse" "this" {
  for_each = local.environments

  display_name = each.value.warehouse_name
  workspace_id = fabric_workspace.this[each.key].id
  description  = "dbt build target for the ${each.key} environment."

  # ForceNew: changing the collation recreates the warehouse and drops its tables.
  configuration = {
    collation_type = var.warehouse_collation
  }
}
