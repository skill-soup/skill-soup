#!/usr/bin/env bash
# select-builder.sh -- Select a builder tool from the local pool using fitness-proportional selection.
#
# Reads builder metadata from .soup/builders/*/_, computes selection probabilities
# proportional to fitness scores, and outputs the selected builder directory path.
#
# Falls back to random selection if all fitness scores are 0.
#
# Environment variables (set by loop.sh or export manually):
#   SOUP_DIR - Path to .soup directory (default: .soup in project root)
#
# Usage: ./scripts/select-builder.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOUP_DIR="${SOUP_DIR:-${PROJECT_ROOT}/.soup}"
BUILDERS_DIR="${SOUP_DIR}/builders"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[select-builder] ERROR: $*" >&2
  exit 1
}

# ── Validate Pool ────────────────────────────────────────────────────────────

if [ ! -d "${BUILDERS_DIR}" ]; then
  die "Builders directory not found at ${BUILDERS_DIR}. Run setup.sh first."
fi

# Collect all builder directories that have a _meta.json
BUILDER_DIRS=()
while IFS= read -r -d '' dir; do
  if [ -f "${dir}/_meta.json" ] && [ -f "${dir}/SKILL.md" ]; then
    BUILDER_DIRS+=("${dir}")
  fi
done < <(find "${BUILDERS_DIR}" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

if [ "${#BUILDER_DIRS[@]}" -eq 0 ]; then
  die "No builders found in ${BUILDERS_DIR}. Run sync-pool.sh to populate."
fi

# ── Read Fitness Scores ─────────────────────────────────────────────────────

declare -a NAMES=()
declare -a FITNESS=()
TOTAL_FITNESS=0

for dir in "${BUILDER_DIRS[@]}"; do
  meta="${dir}/_meta.json"
  name=$(jq -r '.name // "unknown"' "${meta}")
  fitness=$(jq -r '.fitness_score // 0' "${meta}")

  # Ensure fitness is a non-negative number
  if ! [[ "${fitness}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    fitness=0
  fi

  NAMES+=("${name}")
  FITNESS+=("${fitness}")

  # Accumulate total fitness using awk for floating point
  TOTAL_FITNESS=$(awk "BEGIN { printf \"%.6f\", ${TOTAL_FITNESS} + ${fitness} }")
done

BUILDER_COUNT="${#BUILDER_DIRS[@]}"
echo "[select-builder] Pool size: ${BUILDER_COUNT} builders, total fitness: ${TOTAL_FITNESS}" >&2

# ── Selection ────────────────────────────────────────────────────────────────

SELECTED_INDEX=0

# Check if total fitness is effectively zero
IS_ZERO=$(awk "BEGIN { print (${TOTAL_FITNESS} < 0.0001) ? 1 : 0 }")

if [ "${IS_ZERO}" -eq 1 ]; then
  # All fitness scores are 0 (or near-zero) -- use random selection
  echo "[select-builder] All fitness scores are ~0. Using random selection." >&2
  SELECTED_INDEX=$((RANDOM % BUILDER_COUNT))
else
  # Fitness-proportional (roulette wheel) selection
  # Generate a random number between 0 and TOTAL_FITNESS
  RANDOM_THRESHOLD=$(awk "BEGIN { srand(); printf \"%.6f\", rand() * ${TOTAL_FITNESS} }")

  CUMULATIVE=0
  for ((idx = 0; idx < BUILDER_COUNT; idx++)); do
    CUMULATIVE=$(awk "BEGIN { printf \"%.6f\", ${CUMULATIVE} + ${FITNESS[${idx}]} }")
    EXCEEDS=$(awk "BEGIN { print (${CUMULATIVE} >= ${RANDOM_THRESHOLD}) ? 1 : 0 }")
    if [ "${EXCEEDS}" -eq 1 ]; then
      SELECTED_INDEX=${idx}
      break
    fi
  done
fi

SELECTED_DIR="${BUILDER_DIRS[${SELECTED_INDEX}]}"
SELECTED_NAME="${NAMES[${SELECTED_INDEX}]}"
SELECTED_FITNESS="${FITNESS[${SELECTED_INDEX}]}"

echo "[select-builder] Selected: ${SELECTED_NAME} (fitness: ${SELECTED_FITNESS})" >&2

# Output the selected builder directory path to stdout
echo "${SELECTED_DIR}"
