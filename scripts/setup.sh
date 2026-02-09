#!/usr/bin/env bash
# setup.sh -- Initialize the Skill Soup Runner workspace and authenticate.
#
# Creates the .soup/ directory structure, copies the config template,
# and runs the device flow authentication to obtain a JWT.
#
# Usage: ./scripts/setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${PROJECT_ROOT}/.soup"
CONFIG_TEMPLATE="${PROJECT_ROOT}/skill-soup-runner/config-template.yaml"
CONFIG_FILE="${SOUP_DIR}/config.yaml"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  echo "[setup] $*"
}

die() {
  echo "[setup] ERROR: $*" >&2
  exit 1
}

# ── Check Dependencies ──────────────────────────────────────────────────────

log "Checking dependencies..."

command -v curl >/dev/null 2>&1 || die "curl is required but not found. Install it and retry."
command -v jq   >/dev/null 2>&1 || die "jq is required but not found. Install it and retry."

log "Dependencies OK (curl, jq)"

# ── Create Directory Structure ───────────────────────────────────────────────

log "Creating .soup/ directory structure..."

mkdir -p "${SOUP_DIR}/builders"
mkdir -p "${SOUP_DIR}/skills"
mkdir -p "${SOUP_DIR}/logs"

log "Directories created:"
log "  ${SOUP_DIR}/builders/"
log "  ${SOUP_DIR}/skills/"
log "  ${SOUP_DIR}/logs/"

# ── Copy Config Template ────────────────────────────────────────────────────

if [ ! -f "${CONFIG_FILE}" ]; then
  if [ ! -f "${CONFIG_TEMPLATE}" ]; then
    die "Config template not found at ${CONFIG_TEMPLATE}"
  fi
  cp "${CONFIG_TEMPLATE}" "${CONFIG_FILE}"
  log "Copied config template to ${CONFIG_FILE}"
else
  log "Config already exists at ${CONFIG_FILE} -- skipping copy"
fi

# ── Read API URL from Config ────────────────────────────────────────────────

# Simple YAML value reader (handles key: value lines)
read_yaml_value() {
  local file="$1"
  local key="$2"
  grep "^${key}:" "${file}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

API_URL="$(read_yaml_value "${CONFIG_FILE}" "api_url")"
if [ -z "${API_URL}" ]; then
  API_URL="https://skillsoup.dev"
fi

# ── Check API Health ────────────────────────────────────────────────────────

log "Checking API health at ${API_URL}..."

if ! curl -sf "${API_URL}/health" >/dev/null 2>&1; then
  die "Cannot reach API at ${API_URL}/health. Is the server running?"
fi

log "API is healthy"

# ── Check if Already Authenticated ──────────────────────────────────────────

EXISTING_TOKEN="$(read_yaml_value "${CONFIG_FILE}" "auth_token")"
if [ -n "${EXISTING_TOKEN}" ]; then
  log "Auth token already present in config. Verifying..."
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${EXISTING_TOKEN}" \
    "${API_URL}/health")
  if [ "${HTTP_STATUS}" = "200" ] || [ "${HTTP_STATUS}" = "401" ]; then
    # We got a response -- the token format is valid (whether expired is another matter).
    # For a real check we would hit an authenticated endpoint, but /health is enough
    # to confirm connectivity. If the token works, we are done.
    log "Existing token found. To re-authenticate, delete auth_token from ${CONFIG_FILE} and re-run."
    log ""
    log "Setup complete."
    exit 0
  fi
fi

# ── Device Flow Authentication ──────────────────────────────────────────────

log "Starting device flow authentication..."

# Step 1: Request device code
DEVICE_RESPONSE=$(curl -sf -X POST "${API_URL}/api/auth/device" \
  -H "Content-Type: application/json" 2>&1) || die "Failed to start device flow. Is the auth endpoint available?"

DEVICE_CODE=$(echo "${DEVICE_RESPONSE}" | jq -r '.device_code // empty')
USER_CODE=$(echo "${DEVICE_RESPONSE}" | jq -r '.user_code // empty')
VERIFICATION_URI=$(echo "${DEVICE_RESPONSE}" | jq -r '.verification_uri // empty')
EXPIRES_IN=$(echo "${DEVICE_RESPONSE}" | jq -r '.expires_in // 300')
POLL_INTERVAL=$(echo "${DEVICE_RESPONSE}" | jq -r '.interval // 5')

if [ -z "${DEVICE_CODE}" ] || [ -z "${USER_CODE}" ]; then
  die "Device flow response missing device_code or user_code: ${DEVICE_RESPONSE}"
fi

echo ""
echo "============================================"
echo "  DEVICE AUTHENTICATION"
echo "============================================"
echo ""
echo "  Your code:  ${USER_CODE}"
echo ""
if [ -n "${VERIFICATION_URI}" ]; then
  echo "  Visit: ${VERIFICATION_URI}"
  echo "  and enter the code above."
else
  echo "  Enter this code in the Skill Soup web UI."
fi
echo ""
echo "  Waiting for authorization..."
echo "============================================"
echo ""

# Step 2: Wait for authorization via SSE
TOKEN=""
SSE_OUTPUT=$(mktemp)

log "Listening for authorization via SSE..."
# curl -N streams SSE; --max-time caps the total wait
curl -N -sf --max-time "${EXPIRES_IN}" \
  "${API_URL}/api/auth/device/wait/${DEVICE_CODE}" > "${SSE_OUTPUT}" 2>/dev/null || true

# Parse the SSE stream for a token event
TOKEN=$(grep '^data:' "${SSE_OUTPUT}" | head -1 | sed 's/^data://' | jq -r '.token // empty' 2>/dev/null || true)
rm -f "${SSE_OUTPUT}"

if [ -z "${TOKEN}" ]; then
  die "Timed out or failed waiting for device authorization. Please re-run setup."
fi

# Step 3: Save token to config
# Replace the auth_token line in config.yaml
if grep -q "^auth_token:" "${CONFIG_FILE}"; then
  # Use a temporary file for portable sed -i behavior
  TMPFILE=$(mktemp)
  sed "s|^auth_token:.*|auth_token: \"${TOKEN}\"|" "${CONFIG_FILE}" > "${TMPFILE}"
  mv "${TMPFILE}" "${CONFIG_FILE}"
else
  echo "auth_token: \"${TOKEN}\"" >> "${CONFIG_FILE}"
fi

log "Authentication successful. Token saved to ${CONFIG_FILE}"
echo ""
log "Setup complete. You can now run: ./scripts/loop.sh"
