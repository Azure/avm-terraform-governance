#!/bin/bash
set -e

# Helper script to prepare Azure credentials for Terraform in GitHub Actions
# Does not need to be run unless in GH Actions.

declare -A secrets
eval "$(echo "$SECRETS_CONTEXT" | jq -r 'to_entries[] | @sh "secrets[\(.key|tostring)]=\(.value|tostring)"')"

declare -A variables
eval "$(echo "$VARS_CONTEXT" | jq -r 'to_entries[] | @sh "variables[\(.key|tostring)]=\(.value|tostring)"')"

for key in "${!secrets[@]}"; do
  if [[ $key = TF_VAR_* ]]; then
    lowerKey=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    finalKey=${lowerKey/tf_var_/TF_VAR_}
    export "$finalKey"="${secrets[$key]}"
  fi
done

for key in "${!variables[@]}"; do
  if [[ $key = TF_VAR_* ]]; then
    lowerKey=$(echo "$key" | tr '[:upper:]' '[:lower:]')
    finalKey=${lowerKey/tf_var_/TF_VAR_}
    export "$finalKey"="${variables[$key]}"
  fi
done

echo -e "Custom environment variables:\n$(env | grep '^TF_VAR_')"

# Use override values if provided, otherwise use the default values from the environment
export ARM_TENANT_ID="${ARM_TENANT_ID_OVERRIDE:-${ARM_TENANT_ID}}"
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID_OVERRIDE:-${ARM_SUBSCRIPTION_ID}}"
export ARM_CLIENT_ID="${ARM_CLIENT_ID_OVERRIDE:-${ARM_CLIENT_ID}}"

# Set these to allow providers to refresh the tokens
export ARM_OIDC_REQUEST_TOKEN="$ACTIONS_ID_TOKEN_REQUEST_TOKEN"
export ARM_OIDC_REQUEST_URL="$ACTIONS_ID_TOKEN_REQUEST_URL"
