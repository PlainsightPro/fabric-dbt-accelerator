# Holds the raw tables dbt reads. Lives in the same workspace as the warehouse
# because Fabric only allows three-part-name queries within one workspace.
resource "fabric_lakehouse" "source" {
  for_each = local.environments

  display_name = var.source_lakehouse_name
  workspace_id = fabric_workspace.this[each.key].id
  description  = "Raw source tables read by the bronze staging models (${each.key})."

  # Mandatory and ForceNew: the _sources.yml files use named schemas, which a
  # lakehouse without schemas cannot provide.
  configuration = {
    enable_schemas = true
  }
}

# Receives the deployed dbt project under Files/dbt_project on every deploy
# target (dev, accept, prod), kept separate so the deploy script's recursive
# delete never hits source tables.
resource "fabric_lakehouse" "code" {
  for_each = { for key, env in local.environments : key => env if env.deploy_target }

  display_name = var.code_lakehouse_name
  workspace_id = fabric_workspace.this[each.key].id
  description  = "Deployment target for the dbt project code (${each.key})."

  # No configuration block on purpose: this lakehouse only holds Files/.
}
