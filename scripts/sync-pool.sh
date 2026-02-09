#!/usr/bin/env bash
# sync-pool.sh -- Synchronize the local builder pool with the shared pool via the API.
#
# Sends a summary of local builders to POST /api/builders/sync and updates the
# local .soup/builders/ directory based on the response (add new builders, remove culled ones).
#
# Environment variables (set by loop.sh or export manually):
#   API_URL      - Base URL of the API
#   AUTH_TOKEN   - JWT Bearer token
#   AGENT_RUNTIME - Agent runtime identifier
#   SOUP_DIR     - Path to .soup directory
#
# Usage: ./scripts/sync-pool.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${SOUP_DIR:-${PROJECT_ROOT}/.soup}"
CONFIG_FILE="${SOUP_DIR}/config.yaml"
BUILDERS_DIR="${SOUP_DIR}/builders"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[sync-pool] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[sync-pool] $*" >&2
}

read_yaml_value() {
  local file="$1"
  local key="$2"
  grep "^[[:space:]]*${key}:" "${file}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

# ── Read Config ──────────────────────────────────────────────────────────────

API_URL="${API_URL:-$(read_yaml_value "${CONFIG_FILE}" "api_url")}"
AUTH_TOKEN="${AUTH_TOKEN:-$(read_yaml_value "${CONFIG_FILE}" "auth_token")}"
AGENT_RUNTIME="${AGENT_RUNTIME:-$(read_yaml_value "${CONFIG_FILE}" "agent_runtime")}"

API_URL="${API_URL:-https://skillsoup.dev}"
AGENT_RUNTIME="${AGENT_RUNTIME:-unknown}"

if [ -z "${AUTH_TOKEN}" ]; then
  die "No auth token. Run setup.sh or set AUTH_TOKEN."
fi

mkdir -p "${BUILDERS_DIR}"

# ── Build Local Builder Summaries ────────────────────────────────────────────

LOCAL_BUILDERS="[]"

while IFS= read -r -d '' dir; do
  META="${dir}/_meta.json"
  if [ ! -f "${META}" ]; then
    continue
  fi

  BUILDER_SUMMARY=$(jq -c '{
    id: .id,
    name: .name,
    fitness_score: (.fitness_score // 0),
    generation: (.generation // 0),
    skills_produced: (.skills_produced // 0)
  }' "${META}" 2>/dev/null) || continue

  # Verify the summary has an id
  BUILDER_ID=$(echo "${BUILDER_SUMMARY}" | jq -r '.id // empty')
  if [ -z "${BUILDER_ID}" ]; then
    continue
  fi

  LOCAL_BUILDERS=$(echo "${LOCAL_BUILDERS}" | jq --argjson builder "${BUILDER_SUMMARY}" '. + [$builder]')
done < <(find "${BUILDERS_DIR}" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

LOCAL_COUNT=$(echo "${LOCAL_BUILDERS}" | jq 'length')
log "Local pool: ${LOCAL_COUNT} builders"

# ── Send Sync Request ────────────────────────────────────────────────────────

SYNC_PAYLOAD=$(jq -n \
  --argjson local_builders "${LOCAL_BUILDERS}" \
  --arg agent_runtime "${AGENT_RUNTIME}" \
  '{
    local_builders: $local_builders,
    agent_runtime: $agent_runtime
  }')

log "Syncing with ${API_URL}/api/builders/sync..."

RESPONSE=$(curl -sf -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${SYNC_PAYLOAD}" \
  "${API_URL}/api/builders/sync" 2>/dev/null) || true

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

case "${HTTP_CODE}" in
  200|201) ;;
  401) die "Unauthorized (401). Re-run setup.sh." ;;
  *)
    log "Sync request failed (HTTP ${HTTP_CODE}). Continuing with local pool."
    exit 0
    ;;
esac

if [ -z "${BODY}" ]; then
  log "Empty sync response. No changes."
  exit 0
fi

# ── Process Sync Response ────────────────────────────────────────────────────

# The response contains:
#   add: array of full builder objects to add to the local pool
#   cull: array of builder IDs to remove from the local pool

ADD_BUILDERS=$(echo "${BODY}" | jq -c '.add // []')
CULL_IDS=$(echo "${BODY}" | jq -c '.cull // []')

ADD_COUNT=$(echo "${ADD_BUILDERS}" | jq 'length')
CULL_COUNT=$(echo "${CULL_IDS}" | jq 'length')

log "Sync response: ${ADD_COUNT} to add, ${CULL_COUNT} to cull"

# ── Add New Builders ─────────────────────────────────────────────────────────

if [ "${ADD_COUNT}" -gt 0 ]; then
  for ((idx = 0; idx < ADD_COUNT; idx++)); do
    BUILDER=$(echo "${ADD_BUILDERS}" | jq -c ".[${idx}]")
    BUILDER_ID=$(echo "${BUILDER}" | jq -r '.id')
    BUILDER_NAME=$(echo "${BUILDER}" | jq -r '.name // "unknown"')

    NEW_DIR="${BUILDERS_DIR}/${BUILDER_ID}"

    if [ -d "${NEW_DIR}" ]; then
      log "Builder ${BUILDER_NAME} (${BUILDER_ID}) already exists locally. Updating metadata."
    else
      mkdir -p "${NEW_DIR}"
    fi

    # Write SKILL.md
    SKILL_MD=$(echo "${BUILDER}" | jq -r '.skill_md // ""')
    if [ -n "${SKILL_MD}" ]; then
      echo "${SKILL_MD}" > "${NEW_DIR}/SKILL.md"
    fi

    # Write supporting files from files_json
    FILES_JSON=$(echo "${BUILDER}" | jq -c '.files_json // {}')
    if [ "${FILES_JSON}" != "{}" ] && [ "${FILES_JSON}" != "null" ]; then
      echo "${FILES_JSON}" | jq -r 'to_entries[] | @base64' | while read -r entry; do
        FILE_PATH=$(echo "${entry}" | base64 -d | jq -r '.key')
        FILE_CONTENT=$(echo "${entry}" | base64 -d | jq -r '.value')

        # Security: skip paths with .. or absolute paths
        if echo "${FILE_PATH}" | grep -q '\.\.' || echo "${FILE_PATH}" | grep -q '^/'; then
          log "Skipping unsafe file path: ${FILE_PATH}"
          continue
        fi

        # Create parent directory if needed
        FILE_DIR=$(dirname "${NEW_DIR}/${FILE_PATH}")
        mkdir -p "${FILE_DIR}"

        echo "${FILE_CONTENT}" > "${NEW_DIR}/${FILE_PATH}"
      done
    fi

    # Write _meta.json
    META_JSON=$(echo "${BUILDER}" | jq -c '{
      id: .id,
      name: .name,
      description: (.description // ""),
      fitness_score: (.fitness_score // 0),
      generation: (.generation // 0),
      mutation_type: (.mutation_type // "genesis"),
      parent_ids: (.parent_ids // []),
      skills_produced: (.skills_produced // 0),
      agent_runtime: (.agent_runtime // "unknown"),
      synced_at: (now | todate)
    }')
    echo "${META_JSON}" > "${NEW_DIR}/_meta.json"

    log "Added builder: ${BUILDER_NAME} (${BUILDER_ID})"
  done
fi

# ── Cull Builders ────────────────────────────────────────────────────────────

if [ "${CULL_COUNT}" -gt 0 ]; then
  for ((idx = 0; idx < CULL_COUNT; idx++)); do
    CULL_ID=$(echo "${CULL_IDS}" | jq -r ".[${idx}]")
    CULL_DIR="${BUILDERS_DIR}/${CULL_ID}"

    if [ -d "${CULL_DIR}" ]; then
      CULL_NAME="unknown"
      if [ -f "${CULL_DIR}/_meta.json" ]; then
        CULL_NAME=$(jq -r '.name // "unknown"' "${CULL_DIR}/_meta.json")
      fi
      rm -rf "${CULL_DIR}"
      log "Culled builder: ${CULL_NAME} (${CULL_ID})"
    fi
  done
fi

# ── Summary ──────────────────────────────────────────────────────────────────

FINAL_COUNT=$(find "${BUILDERS_DIR}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
log "Sync complete. Local pool now has ${FINAL_COUNT} builders."
