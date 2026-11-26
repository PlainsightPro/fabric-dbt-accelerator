# Capacity resolution and per-environment defaults, applied once here because
# every resource downstream iterates local.environments.

locals {
  capacity = trimspace(var.capacity)

  # One variable takes both forms, so the branch is chosen by shape rather than
  # by which of two mutually exclusive variables was set. A GUID is used as-is;
  # anything else is a display name for the data source below.
  capacity_is_guid = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", local.capacity))
}

# Only instantiated for the display-name form. A name that does not resolve
# fails here in the provider's own read error, not in the postcondition - the
# read has to succeed before any condition is evaluated. The postcondition
# covers the other failure mode, a capacity that exists but is paused.
data "fabric_capacity" "this" {
  count = local.capacity_is_guid ? 0 : 1

  display_name = local.capacity

  lifecycle {
    postcondition {
      condition     = self.state == "Active"
      error_message = "Fabric capacity '${local.capacity}' is ${self.state}, not Active. Resume it in the Azure portal (Fabric capacity > Resume) before applying."
    }
  }
}

locals {
  # The GUID branch, else whatever the name lookup returned.
  default_capacity_id = local.capacity_is_guid ? local.capacity : one(data.fabric_capacity.this[*].id)

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
