# Inputs. `capacity` and `dbt_service_principal_object_id` have no default, so
# Terraform asks for them in the terminal unless a tfvars file supplies them.
# Everything else is optional. Authentication defaults to the Azure CLI.

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

# Deliberately has no default. Terraform prompts for a variable it cannot
# resolve, so a bare `terraform plan` asks for the capacity in the terminal
# rather than failing. scripts/bootstrap.py writes it to terraform.tfvars, so
# the guided path never sees the prompt. This description is what Terraform
# prints above that prompt - keep it self-contained.
variable "capacity" {
  description = <<-EOT
    Fabric capacity hosting every workspace. Either its GUID (Azure Portal >
    the capacity > Properties) or its display name - a GUID is used directly, a
    name is resolved through the fabric_capacity data source, which also fails
    the apply early if the capacity is paused. You must be a capacity
    administrator on it either way. List the ones you can see with:
      az rest --method get --url https://api.fabric.microsoft.com/v1/capacities --resource https://api.fabric.microsoft.com --query "value[].displayName"
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.capacity)) > 0
    error_message = "capacity must not be blank. Give the capacity's GUID or its display name."
  }
}

# --- Naming, roles and environments ------------------------------------------

# Also without a default, for the same reason as capacity above.
variable "dbt_service_principal_object_id" {
  description = <<-EOT
    OBJECT id (not the client id) of the service principal the pipelines
    authenticate as:
      az ad sp show --id <appId> --query id -o tsv
    Leave blank for no service principal at all - every environment must then
    set dbt_sp_role = null, which only makes sense for a local-only trial.
  EOT
  type        = string

  validation {
    condition = (
      trimspace(var.dbt_service_principal_object_id) == "" ||
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", trimspace(var.dbt_service_principal_object_id)))
    )
    error_message = "dbt_service_principal_object_id must be a GUID or blank. A client id will be accepted here and then fail at apply - fetch the object id with `az ad sp show --id <appId> --query id -o tsv`."
  }
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

      Windows : "..\\.venv\\Scripts\\python.exe"
      other   : "../.venv/bin/python"

    Windows needs backslashes, and they must be doubled. local-exec runs the
    command through `cmd /C`, which reads a leading ../ as a switch rather than
    a path and fails with "'..' is not recognized as an internal or external
    command". A single backslash is no good either: \.  and \p are not valid
    HCL escape sequences, so "..\.venv\Scripts\python.exe" will not parse.
  EOT
  type        = string
  default     = "python"

  validation {
    # It is interpolated into a shell command unquoted, and quoting the first
    # token of a `cmd /C` line reliably is not worth the trap. A relative path
    # from infra/ avoids the problem even when the checkout sits under a
    # directory with spaces in its name.
    condition     = can(regex("^\\S+$", var.python_command))
    error_message = "python_command must not contain spaces. Use a relative path such as ..\\\\.venv\\\\Scripts\\\\python.exe (Windows) or ../.venv/bin/python, or put python on PATH."
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
