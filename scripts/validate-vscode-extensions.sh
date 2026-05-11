#!/usr/bin/env bash
# validate-vscode-extensions.sh
#
# Validates VS Code extension IDs found in .vscode/extensions.json and
# .devcontainer/devcontainer.json files.
#
# Checks:
#   1. Extension exists on the VS Code Marketplace.
#   2. If the publisher claims domain "https://microsoft.com",
#      isDomainVerified must be true.
#
# Usage:
#   ./scripts/validate-vscode-extensions.sh [file ...]
#   If no files are given, auto-discovers files under the current directory.
#
# Requires: curl, jq

set -euo pipefail

MARKETPLACE_URL="https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"

# ── helpers ───────────────────────────────────────────────────────────────────

log_info()  { echo "  ℹ  $*"; }
log_ok()    { echo "  ✅ $*"; }
log_fail()  { echo "  ❌ $*" >&2; }
log_header(){ echo ""; echo "==> $*"; }

# Query the VS Code Marketplace for a single extension.
# Returns the JSON response body.
query_marketplace() {
  local ext_id="$1"
  curl -sS "$MARKETPLACE_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json;api-version=7.1-preview.1' \
    -d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"${ext_id}\"}]}],\"flags\":512}"
}

# Extract extension IDs from a .vscode/extensions.json file.
extract_recommendations() {
  jq -r '.recommendations[]? // empty' "$1" 2>/dev/null
}

# Extract extension IDs from a devcontainer.json file.
extract_devcontainer_extensions() {
  jq -r '.customizations.vscode.extensions[]? // empty' "$1" 2>/dev/null
}

# ── discover files ────────────────────────────────────────────────────────────

discover_files() {
  local search_dir="${1:-.}"
  find "$search_dir" -type f \( -path '*/.vscode/extensions.json' -o -name 'devcontainer.json' \) \
    | grep -v node_modules \
    | sort
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  local files=()
  if [[ $# -gt 0 ]]; then
    files=("$@")
  else
    while IFS= read -r f; do
      files+=("$f")
    done < <(discover_files)
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No extension files found."
    exit 0
  fi

  # Collect all extension IDs with their source files.
  declare -A ext_sources  # ext_id -> comma-separated file list
  for file in "${files[@]}"; do
    local ids=()
    case "$file" in
      */extensions.json)
        while IFS= read -r id; do
          [[ -n "$id" ]] && ids+=("$id")
        done < <(extract_recommendations "$file")
        ;;
      */devcontainer.json)
        while IFS= read -r id; do
          [[ -n "$id" ]] && ids+=("$id")
        done < <(extract_devcontainer_extensions "$file")
        ;;
      *)
        log_info "Skipping unknown file type: $file"
        continue
        ;;
    esac

    for id in "${ids[@]}"; do
      if [[ -n "${ext_sources[$id]+_}" ]]; then
        ext_sources[$id]="${ext_sources[$id]}, $file"
      else
        ext_sources[$id]="$file"
      fi
    done
  done

  local unique_ids=("${!ext_sources[@]}")
  local total=${#unique_ids[@]}

  if [[ $total -eq 0 ]]; then
    echo "No extension IDs found in any file."
    exit 0
  fi

  log_header "Validating $total unique extension ID(s)..."
  echo ""

  local failures=()

  for ext_id in "${unique_ids[@]}"; do
    local response
    response=$(query_marketplace "$ext_id")

    # Check if any results were returned.
    local result_count
    result_count=$(echo "$response" | jq '[.results[]?.extensions[]?] | length')

    if [[ "$result_count" -eq 0 ]]; then
      log_fail "$ext_id — NOT FOUND on Marketplace (sources: ${ext_sources[$ext_id]})"
      failures+=("$ext_id (not found)")
      continue
    fi

    # Verify the returned extension matches the requested ID (case-insensitive).
    local returned_id
    returned_id=$(echo "$response" | jq -r '.results[0].extensions[0] | "\(.publisher.publisherName).\(.extensionName)"')

    if [[ "${returned_id,,}" != "${ext_id,,}" ]]; then
      log_fail "$ext_id — ID mismatch: marketplace returned '$returned_id' (sources: ${ext_sources[$ext_id]})"
      failures+=("$ext_id (id mismatch, got $returned_id)")
      continue
    fi

    # Domain verification: only for publishers claiming microsoft.com.
    local domain
    local is_verified
    domain=$(echo "$response" | jq -r '.results[0].extensions[0].publisher.domain // empty')
    is_verified=$(echo "$response" | jq -r '.results[0].extensions[0].publisher.isDomainVerified // false')

    if [[ "$domain" == "https://microsoft.com" ]] && [[ "$is_verified" != "true" ]]; then
      log_fail "$ext_id — claims microsoft.com domain but isDomainVerified=$is_verified (sources: ${ext_sources[$ext_id]})"
      failures+=("$ext_id (unverified microsoft.com domain)")
      continue
    fi

    log_ok "$ext_id"
  done

  echo ""

  if [[ ${#failures[@]} -gt 0 ]]; then
    log_header "FAILED — ${#failures[@]} extension(s) failed validation:"
    for f in "${failures[@]}"; do
      echo "  • $f"
    done
    exit 1
  fi

  log_header "All $total extension(s) passed validation."
}

main "$@"
