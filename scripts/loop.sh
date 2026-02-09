#!/usr/bin/env bash
# loop.sh -- Main generation loop for the Skill Soup Runner.
#
# Reads config from .soup/config.yaml, fetches ideas, generates skills using
# builder tools, validates and publishes them, and periodically evolves builders.
#
# Usage: ./scripts/loop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${PROJECT_ROOT}/.soup"
CONFIG_FILE="${SOUP_DIR}/config.yaml"
LOG_DIR="${SOUP_DIR}/logs"
LOG_FILE="${LOG_DIR}/runner-$(date -u +%Y-%m-%d).log"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  local level="$1"
  shift
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local msg="[${timestamp}] ${level}  $*"
  echo "${msg}" | tee -a "${LOG_FILE}"
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

die() {
  error "$@"
  exit 1
}

# Simple YAML value reader for top-level and nested keys
read_yaml_value() {
  local file="$1"
  local key="$2"
  grep "^[[:space:]]*${key}:" "${file}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"'
}

# ── Validate Environment ────────────────────────────────────────────────────

if [ ! -d "${SOUP_DIR}" ]; then
  die ".soup/ directory not found. Run ./scripts/setup.sh first."
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  die "Config file not found at ${CONFIG_FILE}. Run ./scripts/setup.sh first."
fi

mkdir -p "${LOG_DIR}"

# ── Read Configuration ──────────────────────────────────────────────────────

API_URL="$(read_yaml_value "${CONFIG_FILE}" "api_url")"
AUTH_TOKEN="$(read_yaml_value "${CONFIG_FILE}" "auth_token")"
AGENT_RUNTIME="$(read_yaml_value "${CONFIG_FILE}" "agent_runtime")"
MAX_ITERATIONS="$(read_yaml_value "${CONFIG_FILE}" "max_iterations")"
DELAY_SECONDS="$(read_yaml_value "${CONFIG_FILE}" "delay_between_iterations_seconds")"
EVOLVE_EVERY="$(read_yaml_value "${CONFIG_FILE}" "evolve_every_n_skills")"

# Apply defaults
API_URL="${API_URL:-https://skillsoup.dev}"
AGENT_RUNTIME="${AGENT_RUNTIME:-unknown}"
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
DELAY_SECONDS="${DELAY_SECONDS:-30}"
EVOLVE_EVERY="${EVOLVE_EVERY:-3}"

if [ -z "${AUTH_TOKEN}" ]; then
  die "No auth_token in config. Run ./scripts/setup.sh to authenticate."
fi

export API_URL AUTH_TOKEN AGENT_RUNTIME SOUP_DIR PROJECT_ROOT

# ── Detect Agent Runtime ────────────────────────────────────────────────────

detect_agent_command() {
  case "${AGENT_RUNTIME}" in
    claude-code)
      if command -v claude >/dev/null 2>&1; then
        echo "claude"
      else
        die "claude command not found. Install Claude Code CLI."
      fi
      ;;
    codex)
      if command -v codex >/dev/null 2>&1; then
        echo "codex"
      else
        die "codex command not found. Install Codex CLI."
      fi
      ;;
    gemini-cli)
      if command -v gemini >/dev/null 2>&1; then
        echo "gemini"
      else
        die "gemini command not found. Install Gemini CLI."
      fi
      ;;
    *)
      die "Unknown agent_runtime: ${AGENT_RUNTIME}"
      ;;
  esac
}

AGENT_CMD="$(detect_agent_command)"
info "Using agent runtime: ${AGENT_RUNTIME} (command: ${AGENT_CMD})"

# ── Invoke Agent to Generate Skill ──────────────────────────────────────────

invoke_agent() {
  local builder_path="$1"
  local idea_prompt="$2"
  local idea_context="$3"
  local skill_name="$4"
  local output_dir="${SOUP_DIR}/skills/${skill_name}"

  mkdir -p "${output_dir}"

  local generation_prompt
  generation_prompt="You are generating an Agent Skill. Follow the builder instructions in ${builder_path}/SKILL.md exactly.

IDEA: ${idea_prompt}
CONTEXT: ${idea_context}

Write all output files to: ${output_dir}/
The skill MUST have a SKILL.md with YAML frontmatter containing name, description, version, and license.
The name must be kebab-case, 3-50 characters."

  case "${AGENT_RUNTIME}" in
    claude-code)
      claude -p "${generation_prompt}" --output-dir "${output_dir}" 2>>"${LOG_FILE}" || return 1
      ;;
    codex)
      codex -q "${generation_prompt}" --writable-root "${output_dir}" 2>>"${LOG_FILE}" || return 1
      ;;
    gemini-cli)
      echo "${generation_prompt}" | gemini 2>>"${LOG_FILE}" || return 1
      ;;
  esac
}

# ── Initial Pool Check ──────────────────────────────────────────────────────

BUILDER_COUNT=$(find "${SOUP_DIR}/builders" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [ "${BUILDER_COUNT}" -eq 0 ]; then
  info "Local builder pool is empty. Syncing from shared pool..."
  "${SCRIPT_DIR}/sync-pool.sh" 2>>"${LOG_FILE}" || warn "Initial sync failed -- pool may remain empty."
fi

# ── Main Loop ────────────────────────────────────────────────────────────────

SKILLS_PUBLISHED=0

info "Starting generation loop: max_iterations=${MAX_ITERATIONS}, delay=${DELAY_SECONDS}s, evolve_every=${EVOLVE_EVERY}"

for ((i = 1; i <= MAX_ITERATIONS; i++)); do
  info "Iteration ${i}/${MAX_ITERATIONS} starting"

  # Step 1: Fetch an open idea
  IDEA_JSON=""
  if ! IDEA_JSON=$("${SCRIPT_DIR}/fetch-idea.sh" 2>>"${LOG_FILE}"); then
    warn "No ideas available. Sleeping before retry..."
    sleep "${DELAY_SECONDS}"
    continue
  fi

  IDEA_ID=$(echo "${IDEA_JSON}" | jq -r '.id')
  IDEA_PROMPT=$(echo "${IDEA_JSON}" | jq -r '.prompt')
  IDEA_CONTEXT=$(echo "${IDEA_JSON}" | jq -r '.context // ""')

  info "Fetched idea ${IDEA_ID}: \"${IDEA_PROMPT:0:80}...\""

  # Step 2: Select a builder tool
  BUILDER_PATH=""
  if ! BUILDER_PATH=$("${SCRIPT_DIR}/select-builder.sh" 2>>"${LOG_FILE}"); then
    warn "No builder available. Skipping iteration."
    sleep "${DELAY_SECONDS}"
    continue
  fi

  BUILDER_META="${BUILDER_PATH}/_meta.json"
  BUILDER_NAME="unknown"
  BUILDER_ID="unknown"
  BUILDER_FITNESS="0"
  if [ -f "${BUILDER_META}" ]; then
    BUILDER_NAME=$(jq -r '.name // "unknown"' "${BUILDER_META}")
    BUILDER_ID=$(jq -r '.id // "unknown"' "${BUILDER_META}")
    BUILDER_FITNESS=$(jq -r '.fitness_score // 0' "${BUILDER_META}")
  fi

  info "Selected builder: ${BUILDER_NAME} (id: ${BUILDER_ID}, fitness: ${BUILDER_FITNESS})"

  # Derive a skill name from the idea prompt
  SKILL_NAME=$(echo "${IDEA_PROMPT}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | awk '{for(i=1;i<=NF&&i<=5;i++) printf "%s-",$i}' | sed 's/-$//' | cut -c1-50)
  if [ -z "${SKILL_NAME}" ] || [ "${#SKILL_NAME}" -lt 3 ]; then
    SKILL_NAME="generated-skill-$(date +%s)"
  fi

  SKILL_DIR="${SOUP_DIR}/skills/${SKILL_NAME}"

  # Step 3: Generate the skill
  info "Generating skill '${SKILL_NAME}' using builder ${BUILDER_NAME}..."
  if ! invoke_agent "${BUILDER_PATH}" "${IDEA_PROMPT}" "${IDEA_CONTEXT}" "${SKILL_NAME}"; then
    error "Agent failed to generate skill for idea ${IDEA_ID}. Skipping."
    rm -rf "${SKILL_DIR}"
    sleep "${DELAY_SECONDS}"
    continue
  fi

  # Step 4: Validate the skill
  VALIDATION_ATTEMPTS=0
  VALIDATED=false

  while [ "${VALIDATION_ATTEMPTS}" -lt 3 ]; do
    if "${SCRIPT_DIR}/validate-skill.sh" "${SKILL_DIR}" 2>>"${LOG_FILE}"; then
      VALIDATED=true
      break
    fi
    VALIDATION_ATTEMPTS=$((VALIDATION_ATTEMPTS + 1))
    warn "Validation attempt ${VALIDATION_ATTEMPTS} failed for ${SKILL_NAME}."

    if [ "${VALIDATION_ATTEMPTS}" -lt 3 ]; then
      info "Attempting fix (attempt ${VALIDATION_ATTEMPTS}/3)..."
      # The agent could try to fix the skill here; for the shell runner, we just retry
      sleep 2
    fi
  done

  if [ "${VALIDATED}" != "true" ]; then
    error "Skill ${SKILL_NAME} failed validation after 3 attempts. Skipping."
    rm -rf "${SKILL_DIR}"
    sleep "${DELAY_SECONDS}"
    continue
  fi

  info "Validation passed for ${SKILL_NAME}"

  # Step 5: Publish the skill
  PUBLISHED_ID=""
  if ! PUBLISHED_ID=$("${SCRIPT_DIR}/publish-skill.sh" "${SKILL_DIR}" "${BUILDER_ID}" "${IDEA_ID}" 2>>"${LOG_FILE}"); then
    error "Failed to publish skill ${SKILL_NAME}. Skipping."
    rm -rf "${SKILL_DIR}"
    sleep "${DELAY_SECONDS}"
    continue
  fi

  info "Published skill ${SKILL_NAME} (id: ${PUBLISHED_ID})"
  SKILLS_PUBLISHED=$((SKILLS_PUBLISHED + 1))

  # Clean up the generated skill directory after successful publish
  rm -rf "${SKILL_DIR}"

  # Step 6: Evolve (conditional)
  if [ "$((SKILLS_PUBLISHED % EVOLVE_EVERY))" -eq 0 ] && [ "${SKILLS_PUBLISHED}" -gt 0 ]; then
    info "Evolution threshold reached (${SKILLS_PUBLISHED} skills). Evolving builder ${BUILDER_NAME}..."
    if ! "${SCRIPT_DIR}/evolve.sh" "${BUILDER_PATH}" 2>>"${LOG_FILE}"; then
      warn "Evolution failed for builder ${BUILDER_NAME}. Continuing."
    else
      info "Evolution complete for builder ${BUILDER_NAME}"
    fi
  fi

  # Step 7: Sync pool
  info "Syncing builder pool..."
  if ! "${SCRIPT_DIR}/sync-pool.sh" 2>>"${LOG_FILE}"; then
    warn "Pool sync failed. Continuing with current local pool."
  fi

  info "Iteration ${i}/${MAX_ITERATIONS} complete (total published: ${SKILLS_PUBLISHED})"

  # Delay between iterations (skip on last iteration)
  if [ "${i}" -lt "${MAX_ITERATIONS}" ]; then
    info "Sleeping ${DELAY_SECONDS}s before next iteration..."
    sleep "${DELAY_SECONDS}"
  fi
done

info "Generation loop finished. Total skills published: ${SKILLS_PUBLISHED}"
