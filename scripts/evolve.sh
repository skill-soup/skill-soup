#!/usr/bin/env bash
# evolve.sh -- Create a mutated child builder from a parent builder.
#
# Selects a mutation type, copies the parent builder, applies the mutation,
# publishes the child via publish-builder.sh, and adds it to the local pool.
#
# Mutation types:
#   prompt_tweak      - Small changes to the builder's SKILL.md instructions
#   structure_change  - Alter the directory layout or file organization
#   reference_swap    - Change reference documents or examples
#   hybrid            - Combine elements from multiple mutation types
#
# Usage: ./scripts/evolve.sh <parent-builder-directory>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${SOUP_DIR:-${PROJECT_ROOT}/.soup}"
CONFIG_FILE="${SOUP_DIR}/config.yaml"
BUILDERS_DIR="${SOUP_DIR}/builders"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[evolve] ERROR: $*" >&2
  exit 1
}

log() {
  echo "[evolve] $*" >&2
}

read_yaml_value() {
  local file="$1"
  local key="$2"
  grep "^[[:space:]]*${key}:" "${file}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

# ── Arguments ────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  die "Usage: evolve.sh <parent-builder-directory>"
fi

PARENT_DIR="$1"

if [ ! -d "${PARENT_DIR}" ]; then
  die "Parent builder directory does not exist: ${PARENT_DIR}"
fi

if [ ! -f "${PARENT_DIR}/_meta.json" ]; then
  die "Parent builder has no _meta.json: ${PARENT_DIR}"
fi

if [ ! -f "${PARENT_DIR}/SKILL.md" ]; then
  die "Parent builder has no SKILL.md: ${PARENT_DIR}"
fi

# ── Read Config ──────────────────────────────────────────────────────────────

API_URL="${API_URL:-$(read_yaml_value "${CONFIG_FILE}" "api_url")}"
AUTH_TOKEN="${AUTH_TOKEN:-$(read_yaml_value "${CONFIG_FILE}" "auth_token")}"
AGENT_RUNTIME="${AGENT_RUNTIME:-$(read_yaml_value "${CONFIG_FILE}" "agent_runtime")}"
EVOLVE_EVERY="${EVOLVE_EVERY:-$(read_yaml_value "${CONFIG_FILE}" "evolve_every_n_skills")}"

API_URL="${API_URL:-https://api.skillsoup.dev}"
AGENT_RUNTIME="${AGENT_RUNTIME:-unknown}"

export API_URL AUTH_TOKEN AGENT_RUNTIME SOUP_DIR

# ── Read Parent Metadata ────────────────────────────────────────────────────

PARENT_ID=$(jq -r '.id // empty' "${PARENT_DIR}/_meta.json")
PARENT_NAME=$(jq -r '.name // "unknown"' "${PARENT_DIR}/_meta.json")
PARENT_GENERATION=$(jq -r '.generation // 0' "${PARENT_DIR}/_meta.json")
PARENT_FITNESS=$(jq -r '.fitness_score // 0' "${PARENT_DIR}/_meta.json")
PARENT_SKILLS=$(jq -r '.skills_produced // 0' "${PARENT_DIR}/_meta.json")

log "Parent: ${PARENT_NAME} (gen ${PARENT_GENERATION}, fitness ${PARENT_FITNESS}, skills ${PARENT_SKILLS})"

# ── Check Evolution Threshold ───────────────────────────────────────────────

MIN_SKILLS="${EVOLVE_EVERY:-3}"
if [ "${PARENT_SKILLS}" -lt "${MIN_SKILLS}" ]; then
  log "Parent has produced ${PARENT_SKILLS} skills (min: ${MIN_SKILLS}). Skipping evolution."
  exit 0
fi

# ── Select Mutation Type ────────────────────────────────────────────────────

MUTATION_TYPES=("prompt_tweak" "structure_change" "reference_swap" "hybrid")
MUTATION_WEIGHTS=(40 25 20 15)  # Weighted probability (sums to 100)

# Weighted random selection
RAND=$((RANDOM % 100))
CUMULATIVE=0
SELECTED_MUTATION="prompt_tweak"

for ((idx = 0; idx < ${#MUTATION_TYPES[@]}; idx++)); do
  CUMULATIVE=$((CUMULATIVE + MUTATION_WEIGHTS[idx]))
  if [ "${RAND}" -lt "${CUMULATIVE}" ]; then
    SELECTED_MUTATION="${MUTATION_TYPES[${idx}]}"
    break
  fi
done

log "Selected mutation type: ${SELECTED_MUTATION}"

# ── Create Child Builder ────────────────────────────────────────────────────

CHILD_GENERATION=$((PARENT_GENERATION + 1))
CHILD_TIMESTAMP=$(date +%s)
CHILD_DIR_NAME="child-${PARENT_NAME}-gen${CHILD_GENERATION}-${CHILD_TIMESTAMP}"
CHILD_DIR="${BUILDERS_DIR}/${CHILD_DIR_NAME}"

mkdir -p "${CHILD_DIR}"

# Copy all parent files to child
while IFS= read -r -d '' file; do
  REL_PATH="${file#${PARENT_DIR}/}"

  # Skip _meta.json -- we will create a new one
  if [ "${REL_PATH}" = "_meta.json" ]; then
    continue
  fi

  DEST="${CHILD_DIR}/${REL_PATH}"
  DEST_DIR=$(dirname "${DEST}")
  mkdir -p "${DEST_DIR}"
  cp "${file}" "${DEST}"
done < <(find "${PARENT_DIR}" -type f -print0)

# ── Write Mutation Context ─────────────────────────────────────────────────
# Instead of applying cosmetic HTML comments, write a context file that the
# agent uses to perform a genuine SKILL.md rewrite during the evolution step.

PARENT_SKILL_MD_CONTENT=$(cat "${PARENT_DIR}/SKILL.md")

MUTATION_CONTEXT=$(jq -n \
  --arg mutation_type "${SELECTED_MUTATION}" \
  --arg child_name "${PARENT_NAME}-v${CHILD_GENERATION}" \
  --argjson child_generation "${CHILD_GENERATION}" \
  --arg parent_id "${PARENT_ID}" \
  --arg parent_name "${PARENT_NAME}" \
  --argjson parent_generation "${PARENT_GENERATION}" \
  --arg parent_fitness "${PARENT_FITNESS}" \
  --arg parent_skills "${PARENT_SKILLS}" \
  --arg skill_md "${PARENT_SKILL_MD_CONTENT}" \
  '{
    mutation_type: $mutation_type,
    child_name: $child_name,
    child_generation: $child_generation,
    parent: {
      id: $parent_id,
      name: $parent_name,
      generation: ($parent_generation | tonumber),
      fitness_score: ($parent_fitness | tonumber),
      skills_produced: ($parent_skills | tonumber),
      skill_md: $skill_md
    }
  }')

echo "${MUTATION_CONTEXT}" > "${CHILD_DIR}/_mutation_context.json"

log "Wrote mutation context to ${CHILD_DIR}/_mutation_context.json"

# ── Update Child Name in Frontmatter ────────────────────────────────────────

CHILD_NAME="${PARENT_NAME}-v${CHILD_GENERATION}"
# Truncate to 100 chars for the builder name constraint
CHILD_NAME="${CHILD_NAME:0:100}"

CHILD_SKILL_MD="${CHILD_DIR}/SKILL.md"

# Replace the name in YAML frontmatter
if grep -q "^name:" "${CHILD_SKILL_MD}"; then
  TMPFILE=$(mktemp)
  sed "s/^name:.*/name: ${CHILD_NAME}/" "${CHILD_SKILL_MD}" > "${TMPFILE}"
  mv "${TMPFILE}" "${CHILD_SKILL_MD}"
fi

# ── Write Child _meta.json ──────────────────────────────────────────────────

CHILD_META=$(jq -n \
  --arg name "${CHILD_NAME}" \
  --arg description "Evolved from ${PARENT_NAME} (gen ${PARENT_GENERATION}) via ${SELECTED_MUTATION}" \
  --argjson generation "${CHILD_GENERATION}" \
  --arg mutation_type "${SELECTED_MUTATION}" \
  --arg agent_runtime "${AGENT_RUNTIME}" \
  --argjson parent_ids "[\"${PARENT_ID}\"]" \
  '{
    id: "",
    name: $name,
    description: $description,
    fitness_score: 0,
    generation: $generation,
    mutation_type: $mutation_type,
    agent_runtime: $agent_runtime,
    parent_ids: $parent_ids,
    skills_produced: 0,
    created_at: (now | todate)
  }')

echo "${CHILD_META}" > "${CHILD_DIR}/_meta.json"

log "Created child builder: ${CHILD_NAME} in ${CHILD_DIR}"
log "Mutation context written. The agent should now read _mutation_context.json, rewrite SKILL.md, and POST to the API."
