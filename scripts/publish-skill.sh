#!/usr/bin/env bash
# publish-skill.sh -- Publish a generated skill to the Skill Soup API.
#
# Reads SKILL.md and all supporting files from the skill directory, builds the
# JSON payload, and POSTs it to /api/skills.
#
# Usage: ./scripts/publish-skill.sh <skill-directory> [builder-tool-id] [idea-id]
# Outputs the created skill ID to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${SOUP_DIR:-${PROJECT_ROOT}/.soup}"
CONFIG_FILE="${SOUP_DIR}/config.yaml"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[publish-skill] ERROR: $*" >&2
  exit 1
}

read_yaml_value() {
  local file="$1"
  local key="$2"
  grep "^[[:space:]]*${key}:" "${file}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

# ── Arguments ────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  die "Usage: publish-skill.sh <skill-directory> [builder-tool-id] [idea-id]"
fi

SKILL_DIR="$1"
BUILDER_TOOL_ID="${2:-}"
IDEA_ID="${3:-}"

if [ ! -d "${SKILL_DIR}" ]; then
  die "Skill directory does not exist: ${SKILL_DIR}"
fi

SKILL_MD="${SKILL_DIR}/SKILL.md"
if [ ! -f "${SKILL_MD}" ]; then
  die "SKILL.md not found in ${SKILL_DIR}"
fi

# ── Read Config ──────────────────────────────────────────────────────────────

API_URL="${API_URL:-$(read_yaml_value "${CONFIG_FILE}" "api_url")}"
AUTH_TOKEN="${AUTH_TOKEN:-$(read_yaml_value "${CONFIG_FILE}" "auth_token")}"
AGENT_RUNTIME="${AGENT_RUNTIME:-$(read_yaml_value "${CONFIG_FILE}" "agent_runtime")}"

API_URL="${API_URL:-https://skillsoup.dev}"
AGENT_RUNTIME="${AGENT_RUNTIME:-unknown}"

if [ -z "${AUTH_TOKEN}" ]; then
  die "No auth token. Run setup.sh or set AUTH_TOKEN."
fi

# ── Extract Frontmatter ─────────────────────────────────────────────────────

SKILL_MD_CONTENT=$(cat "${SKILL_MD}")

# Extract name from frontmatter
SKILL_NAME=$(echo "${SKILL_MD_CONTENT}" | sed -n '/^---$/,/^---$/p' | grep "^name:" | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)

# Extract description from frontmatter
SKILL_DESC=$(echo "${SKILL_MD_CONTENT}" | sed -n '/^---$/,/^---$/p' | grep "^description:" | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)

if [ -z "${SKILL_NAME}" ] || [ -z "${SKILL_DESC}" ]; then
  die "Could not extract name or description from SKILL.md frontmatter."
fi

# ── Build files_json ─────────────────────────────────────────────────────────

# Collect all files except SKILL.md into a JSON object { "relative/path": "contents" }
FILES_JSON="{}"

while IFS= read -r -d '' file; do
  REL_PATH="${file#${SKILL_DIR}/}"

  # Skip SKILL.md (it goes in skill_md, not files_json)
  if [ "${REL_PATH}" = "SKILL.md" ]; then
    continue
  fi

  # Skip hidden files and directories
  if echo "${REL_PATH}" | grep -q '^\.' ; then
    continue
  fi

  # Read file content and add to JSON
  FILE_CONTENT=$(cat "${file}")
  FILES_JSON=$(echo "${FILES_JSON}" | jq --arg path "${REL_PATH}" --arg content "${FILE_CONTENT}" '. + {($path): $content}')
done < <(find "${SKILL_DIR}" -type f -print0 | sort -z)

# ── Build Payload ────────────────────────────────────────────────────────────

PAYLOAD=$(jq -n \
  --arg name "${SKILL_NAME}" \
  --arg description "${SKILL_DESC}" \
  --arg skill_md "${SKILL_MD_CONTENT}" \
  --argjson files_json "${FILES_JSON}" \
  --arg builder_tool_id "${BUILDER_TOOL_ID}" \
  --arg agent_runtime "${AGENT_RUNTIME}" \
  '{
    name: $name,
    description: $description,
    skill_md: $skill_md,
    files_json: $files_json,
    builder_tool_id: $builder_tool_id,
    agent_runtime: $agent_runtime
  }')

# Add idea_id if provided
if [ -n "${IDEA_ID}" ]; then
  PAYLOAD=$(echo "${PAYLOAD}" | jq --arg idea_id "${IDEA_ID}" '. + {idea_id: $idea_id}')
fi

# ── Publish ──────────────────────────────────────────────────────────────────

echo "[publish-skill] Publishing '${SKILL_NAME}' to ${API_URL}/api/skills..." >&2

RESPONSE=$(curl -sf -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${API_URL}/api/skills" 2>/dev/null) || true

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

case "${HTTP_CODE}" in
  200|201)
    SKILL_ID=$(echo "${BODY}" | jq -r '.id // .data.id // empty')
    if [ -z "${SKILL_ID}" ]; then
      die "Published successfully but could not extract skill ID from response."
    fi
    echo "[publish-skill] Published successfully: ${SKILL_ID}" >&2
    echo "${SKILL_ID}"
    ;;
  401)
    die "Unauthorized (401). Re-run setup.sh to refresh your token."
    ;;
  409)
    die "Conflict (409). A skill with name '${SKILL_NAME}' may already exist."
    ;;
  422)
    ERROR_DETAIL=$(echo "${BODY}" | jq -r '.error // .message // "Unknown validation error"')
    die "Validation error (422): ${ERROR_DETAIL}"
    ;;
  *)
    die "Failed to publish skill. HTTP ${HTTP_CODE}: ${BODY}"
    ;;
esac
