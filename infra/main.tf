# Capacity resolution and per-environment defaults, applied once here because
# every resource downstream iterates local.environments.

# The normal path: resolve the capacity by display name. Skipped only when the
# capacity_id escape hatch is used.
#
# A name that does not resolve fails here in the provider's own read error, not
# in the postcondition below - the read has to succeed before any condition is
# evaluated. The postcondition covers the other failure mode, a capacity that
# exists but is paused.
data "fabric_capacity" "this" {
  count = var.capacity_name == null ? 0 : 1

  display_name = var.capacity_name

  lifecycle {
    postcondition {
      condition     = self.state == "Active"
      error_message = "Fabric capacity '${var.capacity_name}' is ${self.state}, not Active. Resume it in the Azure portal (Fabric capacity > Resume) before applying."
    }
  }
}

locals {
  # capacity_id wins; otherwise the name lookup.
  default_capacity_id = coalesce(var.capacity_id, one(data.fabric_capacity.this[*].id), "unresolved")

  environments = {
    for key, env in var.environments : key => {
      display_name   = coalesce(env.display_name, "${var.workspace_prefix}-${key}")
      warehouse_name = coalesce(env.warehouse_name, "WH_${key}")
      capacity_id    = coalesce(env.capacity_id, local.default_capacity_id)
      dbt_sp_role    = env.dbt_sp_role
      deploy_target  = env.deploy_target
    }
  }
}
