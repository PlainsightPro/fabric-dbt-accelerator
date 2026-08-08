# Provider, version pinning and state backend.
#
# Auth defaults to the Azure CLI (`az login`). CI flips use_cli off and use_oidc
# on; credentials never live in .tf or .tfvars files.

terraform {
  # >= 1.9 because the auth variables validate against each other, and
  # cross-variable validation blocks landed in 1.9.
  required_version = ">= 1.9, < 2.0"

  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = "~> 1.12.1"
    }
  }

  # TODO: enable before the first apply. This repo lives in OneDrive, where a
  # local terraform.tfstate risks sync conflicts and leaves every connection
  # string in a synced folder. Create the container once (name must be globally
  # unique, 3-24 lowercase alphanumerics):
  #
  #   az group create -n rg-tfstate-dbtacc -l westeurope
  #   az storage account create -n sttfstatedbtacc -g rg-tfstate-dbtacc \
  #     -l westeurope --sku Standard_LRS --kind StorageV2 \
  #     --min-tls-version TLS1_2 --allow-blob-public-access false
  #   az storage account blob-service-properties update -n sttfstatedbtacc \
  #     -g rg-tfstate-dbtacc --enable-versioning true
  #   az storage container create -n tfstate --account-name sttfstatedbtacc \
  #     --auth-mode login
  #
  # Then uncomment, run `terraform init -migrate-state`, and delete the local
  # terraform.tfstate* files.
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate-dbtacc"
  #   storage_account_name = "sttfstatedbtacc"
  #   container_name       = "tfstate"
  #   key                  = "fabric-dbt-accelerator.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "fabric" {
  tenant_id = var.tenant_id

  # Azure CLI by default; CI sets use_cli = false and use_oidc = true.
  use_cli  = var.use_cli
  use_oidc = var.use_oidc

  # Null on purpose. The provider falls back to FABRIC_CLIENT_ID /
  # FABRIC_CLIENT_SECRET, so no secret reaches a .tf file or the state.
  client_id     = var.client_id
  client_secret = var.client_secret
}
