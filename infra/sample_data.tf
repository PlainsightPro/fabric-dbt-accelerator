# Loads the demo CSVs in ../sample into every source lakehouse as Delta tables,
# so `dbt build` works against a freshly applied environment instead of failing
# on missing sources.
#
# Data is not infrastructure, which is why this is a provisioner and not a
# resource: the Fabric provider has no lakehouse-table resource, and Terraform
# tracks only the fact that the load ran, never the table contents. Set
# load_sample_data = false for any environment holding real data.

locals {
  sample_data_dir = "${path.module}/../sample"

  # Any change to the CSVs or to the loader re-runs it. filesha256 over the
  # fileset rather than the directory, because Terraform cannot hash a tree.
  sample_data_hash = sha256(join("", [
    for file in sort(tolist(fileset(local.sample_data_dir, "*.csv"))) :
    filesha256("${local.sample_data_dir}/${file}")
  ]))
}

# terraform_data rather than null_resource: same behaviour, no extra provider.
resource "terraform_data" "sample_data" {
  for_each = var.load_sample_data ? local.environments : {}

  # Load after the roles are granted, so an apply that creates a workspace and
  # its role assignment in one graph cannot write before the grantee can. The
  # loader's own 403 retry absorbs the remaining data-plane propagation lag.
  depends_on = [fabric_workspace_role_assignment.dbt_sp]

  triggers_replace = {
    lakehouse_id = fabric_lakehouse.source[each.key].id
    sample_data  = local.sample_data_hash
    loader       = filesha256("${path.module}/scripts/load_sample_data.py")
  }

  provisioner "local-exec" {
    # Relative paths against path.module, so a repo checkout under a directory
    # with spaces in its name cannot break the quoting.
    working_dir = path.module

    command = join(" ", [
      var.python_command,
      "scripts/load_sample_data.py",
      "--workspace-id ${fabric_workspace.this[each.key].id}",
      "--lakehouse-id ${fabric_lakehouse.source[each.key].id}",
      "--sample-dir ../sample",
      # Pin the loader to the identity the provider itself used. Without this
      # the loader's own precedence takes over: under the default use_cli it
      # would pick up an exported FABRIC_CLIENT_ID and write as a service
      # principal while Terraform created the workspaces as you - a guaranteed
      # 403 on every environment that principal holds no role in.
      "--auth ${var.use_cli ? "cli" : "sp"}",
    ])

    # local-exec inherits the parent environment, so an `az login` session or
    # exported FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET already reach the loader.
    # Only tenant_id needs forwarding, since it may come from a .tfvars file -
    # and only when set, so an unset one cannot shadow an inherited value.
    environment = merge(
      { PYTHONUNBUFFERED = "1" },
      var.tenant_id == null ? {} : { FABRIC_TENANT_ID = var.tenant_id },
    )
  }
}
