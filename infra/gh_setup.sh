# ---------------------------------------------------------------------
# Repository variables - Settings > Secrets and variables > Actions
# ---------------------------------------------------------------------
gh variable set DBT_FABRIC_DATABASE_CI --body "WH_ci"
gh variable set DBT_FABRIC_HOST_CI --body "uk6w2u2e6x6e3gxbg3otimjymi-hsemm4imwrlupojtdev4slda6m.datawarehouse.fabric.microsoft.com"
gh variable set DBT_FABRIC_SOURCE_DATABASE_CI --body "LH_source"

# ---------------------------------------------------------------------
# Environment variables - Settings > Environments
# (create the environments first: gh api -X PUT repos/:owner/:repo/environments/accept)
# ---------------------------------------------------------------------
gh variable set DBT_FABRIC_DATABASE --env accept --body "WH_accept"
gh variable set DBT_FABRIC_DATALAKE_ID --env accept --body "431ae0a1-ef9a-4063-932b-16f04def272c"
gh variable set DBT_FABRIC_HOST --env accept --body "uk6w2u2e6x6e3gxbg3otimjymi-qo2gpfcnssfexjoudul7fp6f4u.datawarehouse.fabric.microsoft.com"
gh variable set DBT_FABRIC_SOURCE_DATABASE --env accept --body "LH_source"
gh variable set DBT_FABRIC_WORKSPACE --env accept --body "9467b483-944d-4b8a-a5d4-1d17f2bfc5e5"
gh variable set DBT_FABRIC_DATABASE --env prod --body "WH_prod"
gh variable set DBT_FABRIC_DATALAKE_ID --env prod --body "02edcce6-32f2-4e17-aa64-45f2166bdf2c"
gh variable set DBT_FABRIC_HOST --env prod --body "uk6w2u2e6x6e3gxbg3otimjymi-m6s67eo2wkvu7icqq2eyccolde.datawarehouse.fabric.microsoft.com"
gh variable set DBT_FABRIC_SOURCE_DATABASE --env prod --body "LH_source"
gh variable set DBT_FABRIC_WORKSPACE --env prod --body "91efa567-b2da-4fab-a050-86898109cb19"

# ---------------------------------------------------------------------
# Secrets - the service principal from docs/CLIENT_SETUP.md step 1.
# Kept out of Terraform so the client secret never reaches the state file.
# ---------------------------------------------------------------------
gh secret set DBT_SP_TENANT_ID   --body "<tenant id>"
gh secret set DBT_SP_CLIENT_ID   --body "<application (client) id>"
gh secret set DBT_SP_CLIENT_SECRET --body "<client secret>"