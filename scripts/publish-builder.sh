#!/usr/bin/env bash
# publish-builder.sh -- Publish a builder tool to the Skill Soup API.
#
# Reads the builder's SKILL.md and supporting files, builds the JSON payload
# with parent lineage and mutation metadata, and POSTs to /api/builders.
#
# Usage: ./scripts/publish-builder.sh <builder-directory> [parent-builder-id]
# Outputs the created builder ID to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${SOUP_DIR:-${PROJECT_ROOT}/.soup}"
CONFIG_FILE="${SOUP_DIR}/config.yaml"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[publish-builder] ERROR: $*" >&2
  exit 1
}

read_yaml_value() {
  local file="$1"
  local key="$2"
  grep "^[[:space:]]*${key}:" "${file}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

# ── Arguments ────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  die "Usage: publish-builder.sh <builder-directory> [parent-builder-id]"
fi

BUILDER_DIR="$1"
PARENT_ID="${2:-}"

if [ ! -d "${BUILDER_DIR}" ]; then
  die "Builder directory does not exist: ${BUILDER_DIR}"
fi

BUILDER_MD="${BUILDER_DIR}/SKILL.md"
if [ ! -f "${BUILDER_MD}" ]; then
  die "SKILL.md not found in ${BUILDER_DIR}"
fi

META_FILE="${BUILDER_DIR}/_meta.json"

# ── Read Config ──────────────────────────────────────────────────────────────

API_URL="${API_URL:-$(read_yaml_value "${CONFIG_FILE}" "api_url")}"
AUTH_TOKEN="${AUTH_TOKEN:-$(read_yaml_value "${CONFIG_FILE}" "auth_token")}"
AGENT_RUNTIME="${AGENT_RUNTIME:-$(read_yaml_value "${CONFIG_FILE}" "agent_runtime")}"

API_URL="${API_URL:-https://api.skillsoup.dev}"
AGENT_RUNTIME="${AGENT_RUNTIME:-unknown}"

if [ -z "${AUTH_TOKEN}" ]; then
  die "No auth token. Run setup.sh or set AUTH_TOKEN."
fi

# ── Read Builder Metadata ───────────────────────────────────────────────────

BUILDER_MD_CONTENT=$(cat "${BUILDER_MD}")

# Extract name from frontmatter
BUILDER_NAME=$(echo "${BUILDER_MD_CONTENT}" | sed -n '/^---$/,/^---$/p' | grep "^name:" | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)

# Extract description from frontmatter
BUILDER_DESC=$(echo "${BUILDER_MD_CONTENT}" | sed -n '/^---$/,/^---$/p' | grep "^description:" | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)

if [ -z "${BUILDER_NAME}" ] || [ -z "${BUILDER_DESC}" ]; then
  die "Could not extract name or description from builder SKILL.md frontmatter."
fi

# Read mutation_type and generation from _meta.json if it exists
MUTATION_TYPE="genesis"
GENERATION=0
PARENT_IDS="[]"

if [ -f "${META_FILE}" ]; then
  MUTATION_TYPE=$(jq -r '.mutation_type // "genesis"' "${META_FILE}")
  GENERATION=$(jq -r '.generation // 0' "${META_FILE}")
  PARENT_IDS=$(jq -c '.parent_ids // []' "${META_FILE}")
fi

# If a parent ID was passed as argument, add it to parent_ids
if [ -n "${PARENT_ID}" ]; then
  PARENT_IDS=$(echo "${PARENT_IDS}" | jq --arg pid "${PARENT_ID}" '. + [$pid] | unique')
fi

# ── Build files_json ─────────────────────────────────────────────────────────

FILES_JSON="{}"

while IFS= read -r -d '' file; do
  REL_PATH="${file#${BUILDER_DIR}/}"

  # Skip SKILL.md (goes in skill_md) and _meta.json (internal)
  if [ "${REL_PATH}" = "SKILL.md" ] || [ "${REL_PATH}" = "_meta.json" ]; then
    continue
  fi

  # Skip hidden files
  if echo "${REL_PATH}" | grep -q '^\.' ; then
    continue
  fi

  FILE_CONTENT=$(cat "${file}")
  FILES_JSON=$(echo "${FILES_JSON}" | jq --arg path "${REL_PATH}" --arg content "${FILE_CONTENT}" '. + {($path): $content}')
done < <(find "${BUILDER_DIR}" -type f -print0 | sort -z)

# ── Build Payload ────────────────────────────────────────────────────────────

PAYLOAD=$(jq -n \
  --arg name "${BUILDER_NAME}" \
  --arg description "${BUILDER_DESC}" \
  --arg skill_md "${BUILDER_MD_CONTENT}" \
  --argjson files_json "${FILES_JSON}" \
  --argjson parent_ids "${PARENT_IDS}" \
  --arg mutation_type "${MUTATION_TYPE}" \
  --arg agent_runtime "${AGENT_RUNTIME}" \
  '{
    name: $name,
    description: $description,
    skill_md: $skill_md,
    files_json: $files_json,
    parent_ids: $parent_ids,
    mutation_type: $mutation_type,
    agent_runtime: $agent_runtime
  }')

# ── Publish ──────────────────────────────────────────────────────────────────

echo "[publish-builder] Publishing builder '${BUILDER_NAME}' (gen ${GENERATION}, mutation: ${MUTATION_TYPE})..." >&2

RESPONSE=$(curl -sf -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${API_URL}/api/builders" 2>/dev/null) || true

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

case "${HTTP_CODE}" in
  200|201)
    BUILDER_ID=$(echo "${BODY}" | jq -r '.id // .data.id // empty')
    if [ -z "${BUILDER_ID}" ]; then
      die "Published successfully but could not extract builder ID from response."
    fi
    echo "[publish-builder] Published successfully: ${BUILDER_ID}" >&2

    # Update local _meta.json with the server-assigned ID
    if [ -f "${META_FILE}" ]; then
      UPDATED_META=$(jq --arg id "${BUILDER_ID}" '.id = $id' "${META_FILE}")
      echo "${UPDATED_META}" > "${META_FILE}"
    fi

    echo "${BUILDER_ID}"
    ;;
  401)
    die "Unauthorized (401). Re-run setup.sh to refresh your token."
    ;;
  409)
    die "Conflict (409). A builder with name '${BUILDER_NAME}' may already exist."
    ;;
  422)
    ERROR_DETAIL=$(echo "${BODY}" | jq -r '.error // .message // "Unknown validation error"')
    die "Validation error (422): ${ERROR_DETAIL}"
    ;;
  *)
    die "Failed to publish builder. HTTP ${HTTP_CODE}: ${BODY}"
    ;;
esac
