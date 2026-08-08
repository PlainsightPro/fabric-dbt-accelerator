# Inputs. Required: capacity_name, plus dbt_service_principal_object_id if any
# environment sets dbt_sp_role. Authentication defaults to the Azure CLI.

# --- Authentication ----------------------------------------------------------

variable "tenant_id" {
  description = "Entra tenant GUID. Optional under CLI auth - `az login --tenant <id>` already pins it."
  type        = string
  default     = null
}

variable "use_cli" {
  description = "Authenticate as the signed-in Azure CLI user. The default for interactive development."
  type        = bool
  default     = true
}

variable "use_oidc" {
  description = "Authenticate via OpenID Connect (GitHub Actions federated credentials). Set use_cli = false alongside it."
  type        = bool
  default     = false

  validation {
    condition     = !(var.use_cli && var.use_oidc)
    error_message = "Set only one of use_cli / use_oidc. For CI: -var use_cli=false -var use_oidc=true."
  }
}

variable "client_id" {
  description = "Service principal application id. Leave null and export FABRIC_CLIENT_ID instead."
  type        = string
  default     = null
}

variable "client_secret" {
  description = "Service principal secret. Leave null and export FABRIC_CLIENT_SECRET - never set this in a .tf or .tfvars file."
  type        = string
  default     = null
  sensitive   = true
}

# --- Capacity ----------------------------------------------------------------

variable "capacity_name" {
  description = "Display name of the Fabric capacity hosting every workspace, resolved through the fabric_capacity data source so the config is portable across tenants. Requires capacity admin rights."
  type        = string
  default     = null

  validation {
    condition     = var.capacity_name == null ? true : length(trimspace(var.capacity_name)) > 0
    error_message = "capacity_name must not be blank. Use the capacity's display name as shown by `az rest --method get --url https://api.fabric.microsoft.com/v1/capacities --resource https://api.fabric.microsoft.com`."
  }
}

variable "capacity_id" {
  description = "Escape hatch: the capacity GUID, skipping the name lookup. Use only where the principal cannot list capacities. Set exactly one of capacity_name / capacity_id."
  type        = string
  default     = null
}

# --- Naming, roles and environments ------------------------------------------

variable "dbt_service_principal_object_id" {
  description = "OBJECT id (not client id) of the service principal the pipelines authenticate as: `az ad sp show --id <appId> --query id -o tsv`."
  type        = string
  default     = null
}

variable "workspace_prefix" {
  description = "Prefix for generated workspace names, e.g. dbt-accelerator-ci."
  type        = string
  default     = "dbt-accelerator"
}

variable "source_lakehouse_name" {
  description = "Source lakehouse name, identical in every workspace so one DBT_FABRIC_SOURCE_DATABASE value works for all targets."
  type        = string
  default     = "LH_source"
}

variable "code_lakehouse_name" {
  description = "Lakehouse receiving the deployed dbt project at Files/dbt_project (deploy targets only). Its GUID is DBT_FABRIC_DATALAKE_ID."
  type        = string
  default     = "LH_dbt_code"
}

variable "warehouse_collation" {
  description = "Collation for every warehouse. Pinned explicitly because it is ForceNew."
  type        = string
  default     = "Latin1_General_100_BIN2_UTF8"

  validation {
    condition = contains([
      "Latin1_General_100_BIN2_UTF8",
      "Latin1_General_100_CI_AS_KS_WS_SC_UTF8",
    ], var.warehouse_collation)
    error_message = "warehouse_collation must be Latin1_General_100_BIN2_UTF8 or Latin1_General_100_CI_AS_KS_WS_SC_UTF8."
  }
}

# --- Sample data -------------------------------------------------------------

variable "load_sample_data" {
  description = <<-EOT
    Load the demo CSVs in ../sample into every source lakehouse as Delta tables
    (raw_sales / raw_hr / mdm) at the end of the apply, so `dbt build` works
    immediately. See sample_data.tf.

    Requires python on PATH with requirements/requirements-setup.txt
    installed. Set to false for environments holding real data - the loader
    overwrites the six demo tables and nothing else, but a lakehouse fed by a
    real pipeline has no business carrying demo rows.
  EOT
  type        = bool
  default     = true
}

variable "python_command" {
  description = <<-EOT
    Interpreter used to run scripts/load_sample_data.py. The default works when
    a virtualenv is active. Otherwise point it at the venv relative to infra/:
    ../.venv/Scripts/python.exe on Windows, ../.venv/bin/python elsewhere.
  EOT
  type        = string
  default     = "python"

  validation {
    # It is interpolated into a shell command unquoted, and quoting the first
    # token of a `cmd /C` line reliably is not worth the trap. A relative path
    # from infra/ avoids the problem even when the checkout sits under a
    # directory with spaces in its name.
    condition     = can(regex("^\\S+$", var.python_command))
    error_message = "python_command must not contain spaces. Use a relative path such as ../.venv/Scripts/python.exe, or put python on PATH."
  }
}

variable "environments" {
  description = <<-EOT
    One entry per dbt target. Each becomes a workspace with a warehouse and a
    source lakehouse; deploy_target adds the code lakehouse.

      display_name   - workspace name (default "<workspace_prefix>-<key>")
      warehouse_name - warehouse name (default "WH_<key>")
      capacity_id    - per-environment capacity override
      dbt_sp_role    - Admin | Contributor | Member | Viewer, or null for none
      deploy_target  - true for environments the pipelines deploy code to
  EOT

  type = map(object({
    display_name   = optional(string)
    warehouse_name = optional(string)
    capacity_id    = optional(string)
    dbt_sp_role    = optional(string)
    deploy_target  = optional(bool, false)
  }))

  default = {
    dev    = { dbt_sp_role = null } # humans, Azure CLI auth
    ci     = { dbt_sp_role = "Contributor" }
    accept = { dbt_sp_role = "Contributor", deploy_target = true }
    prod   = { dbt_sp_role = "Contributor", deploy_target = true }
  }

  validation {
    condition = alltrue([
      for env in var.environments :
      env.dbt_sp_role == null || contains(["Admin", "Contributor", "Member", "Viewer"], coalesce(env.dbt_sp_role, "Contributor"))
    ])
    error_message = "dbt_sp_role must be null or one of Admin, Contributor, Member, Viewer."
  }
}
