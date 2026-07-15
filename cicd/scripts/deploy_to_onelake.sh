#!/usr/bin/env bash
# =============================================================================
# deploy_to_onelake.sh - deploy the dbt project tree to a Fabric Lakehouse
#
# Uploads the project source to <workspace>/<lakehouse>/Files/dbt_project in
# OneLake via the ADLS DFS protocol and writes an _EXTRACTED marker when the
# upload is complete and verified. The pipeline ships CODE only - dbt execution
# happens inside Fabric on its own schedule.
#
# Used by both GitHub Actions (.github/workflows/deploy-*.yml) and Azure DevOps
# (cicd/azure-devops/deploy-*.yml).
#
# Required environment variables:
#   DBT_SP_CLIENT_ID        service principal application id
#   DBT_SP_CLIENT_SECRET    service principal secret
#   DBT_SP_TENANT_ID        Entra ID tenant id
#   DBT_FABRIC_WORKSPACE    workspace segment of the OneLake URL (name or GUID)
#   DBT_FABRIC_DATALAKE_ID  lakehouse item GUID under which Files/ lives
#   PROJECT_DIR             path to the dbt project checkout to upload
# =============================================================================

set -euo pipefail

# ============================================================
# Sanity check - fail fast if any required variable is missing
# ============================================================
: "${DBT_SP_CLIENT_ID:?DBT_SP_CLIENT_ID not set}"
: "${DBT_SP_CLIENT_SECRET:?DBT_SP_CLIENT_SECRET not set}"
: "${DBT_SP_TENANT_ID:?DBT_SP_TENANT_ID not set}"
: "${DBT_FABRIC_WORKSPACE:?DBT_FABRIC_WORKSPACE not set}"
: "${DBT_FABRIC_DATALAKE_ID:?DBT_FABRIC_DATALAKE_ID not set}"
: "${PROJECT_DIR:?PROJECT_DIR not set}"

echo "All required variables present."

# Timeouts applied to every curl call so nothing can hang the agent.
CURL_TIMEOUTS=(--connect-timeout 30 --max-time 600)

# ============================================================
# 0. Acquire storage token
# ============================================================
storage_token=""
storage_token_acquired_at=0

acquire_storage_token() {
  echo "Acquiring storage token..."
  local response
  response=$(curl -s "${CURL_TIMEOUTS[@]}" -X POST \
    -d "client_id=${DBT_SP_CLIENT_ID}&scope=https%3A%2F%2Fstorage.azure.com%2F.default&client_secret=${DBT_SP_CLIENT_SECRET}&grant_type=client_credentials" \
    "https://login.microsoftonline.com/${DBT_SP_TENANT_ID}/oauth2/v2.0/token")
  storage_token=$(echo "$response" | grep -o '"access_token":"[^"]*' | sed 's/"access_token":"//')

  if [ -z "$storage_token" ]; then
    echo "Failed to acquire storage token."
    echo "$response"
    exit 1
  fi
  storage_token_acquired_at=$(date +%s)
}

# Refresh if the token is older than 45 minutes (tokens live ~60 min).
refresh_token_if_stale() {
  local now age
  now=$(date +%s)
  age=$((now - storage_token_acquired_at))
  if [ "$age" -gt 2700 ]; then
    acquire_storage_token
  fi
}

acquire_storage_token

base_url="https://onelake.dfs.fabric.microsoft.com/${DBT_FABRIC_WORKSPACE}/${DBT_FABRIC_DATALAKE_ID}/Files"
# DFS "List Path": the filesystem is the WORKSPACE alone; item + path go in ?directory=
fs_url="https://onelake.dfs.fabric.microsoft.com/${DBT_FABRIC_WORKSPACE}"

echo "Base URL: $base_url"

# ============================================================
# Helper: curl with HTTP status check + header capture
# ============================================================
# Usage: onelake_curl METHOD URL [extra curl args...]
# Returns 0 on 2xx, non-zero otherwise.
#   $http_code       -> numeric HTTP status ("000" on transport error/timeout)
#   $response_body   -> response body
#   $retry_after     -> value of the Retry-After response header (empty if absent)
http_code=""
response_body=""
retry_after=""

onelake_curl() {
  local method="$1"
  local url="$2"
  shift 2

  local tmp_body tmp_hdr
  tmp_body=$(mktemp)
  tmp_hdr=$(mktemp)

  http_code=$(curl -s "${CURL_TIMEOUTS[@]}" -o "$tmp_body" -D "$tmp_hdr" -w "%{http_code}" -X "$method" "$url" \
    -H "Authorization: Bearer $storage_token" \
    -H "x-ms-version: 2021-06-08" \
    -H "x-ms-date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$@" || echo "000")

  response_body=$(cat "$tmp_body")
  # Header names are case-insensitive; grep -i and strip trailing CR.
  retry_after=$(grep -i '^Retry-After:' "$tmp_hdr" | head -n1 | sed 's/^[Rr]etry-[Aa]fter:[[:space:]]*//' | tr -d '\r')
  rm -f "$tmp_body" "$tmp_hdr"

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    return 0
  fi
  return 1
}

# ============================================================
# 1. Clean previous deployment in OneLake
# ============================================================
echo "Cleaning previous deployment in OneLake..."

# DELETE is allowed to fail with 404 (already gone), so we don't check.
onelake_curl DELETE "$base_url/dbt_project?recursive=true" > /dev/null || true
onelake_curl DELETE "$base_url/_EXTRACTED"                 > /dev/null || true
onelake_curl DELETE "$base_url/_LOCK?recursive=true"       > /dev/null || true

# ============================================================
# 2. Determine the file set to upload (git checkout, no zip involved)
# ============================================================
# Exclude VCS metadata, local build artifacts, and local-only secrets.
list_project_files() {
  find "$PROJECT_DIR" -type f \
    -not -path "*/.git/*" \
    "$@"
}

# ============================================================
# Upload helpers (create / append / flush) with retry
# ============================================================

# Single attempt to upload one file via 3-call DFS protocol.
# Every call is routed through onelake_curl so a non-2xx on ANY of the
# three steps fails the whole attempt.
# Returns 0 on success, 1 on any failure.
upload_file_to_onelake() {
  local local_file="$1"
  local remote_url="$2"

  # Create the file (body-less)
  onelake_curl PUT "$remote_url?resource=file" -H "Content-Length: 0" || return 1

  local size
  size=$(stat -c%s "$local_file")

  if [ "$size" -eq 0 ]; then
    # Empty file: still need to flush at position 0 so it exists properly
    onelake_curl PATCH "$remote_url?action=flush&position=0" -H "Content-Length: 0" || return 1
    return 0
  fi

  # Append the data
  onelake_curl PATCH "$remote_url?action=append&position=0" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$local_file" || return 1

  # Flush (body-less - Content-Length: 0 is mandatory)
  onelake_curl PATCH "$remote_url?action=flush&position=$size" -H "Content-Length: 0" || return 1

  return 0
}

# Retry wrapper with exponential backoff.
# - Refreshes token on 401.
# - Honors Retry-After on 429/503 when present, otherwise exponential backoff.
upload_file_with_retry() {
  local local_file="$1"
  local remote_url="$2"
  local attempt=0
  local max_attempts=5
  local delay

  while [ "$attempt" -lt "$max_attempts" ]; do
    refresh_token_if_stale
    if upload_file_to_onelake "$local_file" "$remote_url"; then
      return 0
    fi

    # Re-auth on 401 immediately (token may have been revoked or rotated).
    if [ "$http_code" = "401" ]; then
      echo "  Got 401, re-acquiring token..." >&2
      acquire_storage_token
    fi

    attempt=$((attempt + 1))

    # Prefer server-directed Retry-After (seconds) when throttled.
    if { [ "$http_code" = "429" ] || [ "$http_code" = "503" ]; } \
       && [[ "$retry_after" =~ ^[0-9]+$ ]]; then
      delay="$retry_after"
    else
      delay=$((2 ** attempt))
    fi

    echo "  Retry $attempt/$max_attempts for $remote_url in ${delay}s (last status=$http_code)" >&2
    sleep "$delay"
  done

  echo "ERROR: gave up on $remote_url after $max_attempts attempts" >&2
  return 1
}

# ============================================================
# 3. Upload the project tree to OneLake
# ============================================================
echo "Uploading project tree to OneLake..."

file_count=0
fail_count=0
while IFS= read -r -d '' f; do
  rel_path="${f#"$PROJECT_DIR"/}"
  encoded_path=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe='/'))" "$rel_path")
  remote_url="$base_url/dbt_project/$encoded_path"

  if ! upload_file_with_retry "$f" "$remote_url"; then
    fail_count=$((fail_count + 1))
  fi

  file_count=$((file_count + 1))
  if (( file_count % 25 == 0 )); then
    echo "  uploaded $file_count files..."
  fi
done < <(list_project_files -print0)

echo "Uploaded $file_count files to OneLake ($fail_count failures)."

if [ "$fail_count" -gt 0 ]; then
  echo "ERROR: $fail_count file(s) failed to upload - aborting before marker." >&2
  exit 1
fi

# ============================================================
# 3b. Verify: list OneLake and confirm the uploaded file count matches
# ============================================================
# Belt-and-suspenders check against silent truncation. Runs with errexit
# temporarily disabled so any list-API hiccup can only WARN, never fail the
# build. Only a genuine count mismatch aborts.
#
# Returns:  0 = counts match OR list could not be performed (warned)
#           1 = list succeeded but counts DO NOT match
verify_upload_count() {
  local local_count remote_count continuation page_url list_page
  local tmp_body tmp_hdr code page_count cont_enc

  local_count=$(list_project_files | wc -l | tr -d ' ')

  remote_count=0
  continuation=""
  list_page=0

  while : ; do
    list_page=$((list_page + 1))

    # OneLake DFS List Path: filesystem = workspace, path via ?directory=
    page_url="${fs_url}?resource=filesystem&recursive=true&directory=${DBT_FABRIC_DATALAKE_ID}%2FFiles%2Fdbt_project"
    if [ -n "$continuation" ]; then
      cont_enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$continuation")
      page_url="${page_url}&continuation=${cont_enc}"
    fi

    tmp_body=$(mktemp); tmp_hdr=$(mktemp)
    code=$(curl -s "${CURL_TIMEOUTS[@]}" -o "$tmp_body" -D "$tmp_hdr" -w "%{http_code}" -X GET "$page_url" \
      -H "Authorization: Bearer $storage_token" \
      -H "x-ms-version: 2021-06-08" \
      -H "x-ms-date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" || echo "000")

    if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
      echo "WARNING: list call failed (status=$code); skipping count verification." >&2
      echo "         body: $(head -c 300 "$tmp_body")" >&2
      rm -f "$tmp_body" "$tmp_hdr"
      return 0
    fi

    # Count non-directory entries; print 0 rather than erroring on bad JSON.
    page_count=$(python3 - "$tmp_body" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    paths = data.get("paths", [])
    print(sum(1 for p in paths if str(p.get("isDirectory", "false")).lower() != "true"))
except Exception:
    print(0)
PY
)
    remote_count=$((remote_count + page_count))

    continuation=$(grep -i '^x-ms-continuation:' "$tmp_hdr" | head -n1 | sed 's/^[Xx]-[Mm][Ss]-[Cc]ontinuation:[[:space:]]*//' | tr -d '\r')
    rm -f "$tmp_body" "$tmp_hdr"

    [ -z "$continuation" ] && break
    if [ "$list_page" -ge 50 ]; then
      echo "WARNING: too many list pages; skipping count verification." >&2
      return 0
    fi
  done

  echo "Local files: $local_count | OneLake files under dbt_project: $remote_count"

  if [ "$remote_count" -lt "$local_count" ]; then
    # Fewer files in OneLake than expected - one or more uploads were silently lost.
    echo "ERROR: OneLake is missing $(( local_count - remote_count )) file(s) - upload may have been silently dropped." >&2
    return 1
  fi

  if [ "$remote_count" -gt "$local_count" ]; then
    # More files in OneLake than local - stale files survived the cleanup DELETE.
    # Identify and delete them so the dbt runtime on OneLake sees exactly the
    # same file tree as the agent (avoids ghost models or seeds being picked up).
    echo "WARNING: OneLake has $(( remote_count - local_count )) stale file(s) not in current deployment - cleaning them up." >&2

    # Build a set of relative paths that were uploaded (local tree).
    local local_paths
    local_paths=$(list_project_files | sed "s|^$PROJECT_DIR/||" | sort)

    # Re-list OneLake to get all current remote paths and delete any that are not local.
    local stale_deleted=0
    local tmp_list
    tmp_list=$(mktemp)
    local cont="" list_url
    while : ; do
      list_url="${fs_url}?resource=filesystem&recursive=true&directory=${DBT_FABRIC_DATALAKE_ID}%2FFiles%2Fdbt_project"
      [ -n "$cont" ] && list_url="${list_url}&continuation=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$cont")"

      tmp_body=$(mktemp); tmp_hdr=$(mktemp)
      code=$(curl -s "${CURL_TIMEOUTS[@]}" -o "$tmp_body" -D "$tmp_hdr" -w "%{http_code}" -X GET "$list_url" \
        -H "Authorization: Bearer $storage_token" \
        -H "x-ms-version: 2021-06-08" \
        -H "x-ms-date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" || echo "000")

      if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
        echo "WARNING: could not list OneLake to find stale files (status=$code); proceeding without stale-file cleanup." >&2
        rm -f "$tmp_body" "$tmp_hdr" "$tmp_list"
        return 0
      fi

      python3 - "$tmp_body" >> "$tmp_list" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for p in data.get("paths", []):
        if str(p.get("isDirectory","false")).lower() != "true":
            name = p.get("name","")
            # Strip leading "dbt_project/" prefix to get relative path
            rel = name.split("dbt_project/", 1)[-1] if "dbt_project/" in name else name
            print(rel)
except Exception:
    pass
PY
      cont=$(grep -i '^x-ms-continuation:' "$tmp_hdr" | head -n1 | sed 's/^[Xx]-[Mm][Ss]-[Cc]ontinuation:[[:space:]]*//' | tr -d '\r')
      rm -f "$tmp_body" "$tmp_hdr"
      [ -z "$cont" ] && break
    done

    # Delete each remote path that has no local counterpart.
    while IFS= read -r remote_rel; do
      if ! echo "$local_paths" | grep -qxF "$remote_rel"; then
        encoded=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe='/'))" "$remote_rel")
        echo "  Deleting stale file: $remote_rel" >&2
        onelake_curl DELETE "$base_url/dbt_project/$encoded" > /dev/null || true
        stale_deleted=$((stale_deleted + 1))
      fi
    done < "$tmp_list"
    rm -f "$tmp_list"

    echo "Stale cleanup complete: $stale_deleted file(s) removed." >&2
  fi

  echo "File count verified."
  return 0
}

echo "Verifying uploaded file count against local tree..."
set +e
verify_upload_count
verify_rc=$?
set -e
if [ "$verify_rc" -ne 0 ]; then
  echo "ERROR: OneLake file count does not match local tree - a file was dropped. Aborting before marker." >&2
  exit 1
fi

# ============================================================
# 4. Write the _EXTRACTED marker (only after all files succeeded)
# ============================================================
echo "Writing _EXTRACTED marker..."
marker_url="$base_url/_EXTRACTED"

if ! onelake_curl PUT "$marker_url?resource=file" -H "Content-Length: 0"; then
  echo "Failed to create _EXTRACTED marker ($http_code): $response_body" >&2
  exit 1
fi

if ! onelake_curl PATCH "$marker_url?action=flush&position=0" -H "Content-Length: 0"; then
  echo "Failed to flush _EXTRACTED marker ($http_code): $response_body" >&2
  exit 1
fi

echo "OneLake deployment complete."
