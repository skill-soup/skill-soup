#!/usr/bin/env bash
# validate-skill.sh -- Validate a generated skill directory.
#
# Checks that the skill directory meets all requirements for publishing:
#   - SKILL.md exists and has YAML frontmatter with name and description
#   - name is kebab-case, 3-50 characters
#   - No files exceed 100KB
#   - No file paths contain ".." or absolute paths
#
# Usage: ./scripts/validate-skill.sh <skill-directory>
# Exit 0 if valid, exit 1 with error message if not.
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[validate-skill] FAIL: $*" >&2
  exit 1
}

warn() {
  echo "[validate-skill] WARN: $*" >&2
}

# ── Arguments ────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  die "Usage: validate-skill.sh <skill-directory>"
fi

SKILL_DIR="$1"

if [ ! -d "${SKILL_DIR}" ]; then
  die "Skill directory does not exist: ${SKILL_DIR}"
fi

SKILL_MD="${SKILL_DIR}/SKILL.md"

# ── Check 1: SKILL.md exists ────────────────────────────────────────────────

if [ ! -f "${SKILL_MD}" ]; then
  die "SKILL.md not found in ${SKILL_DIR}"
fi

# ── Check 2: YAML frontmatter exists and is valid ───────────────────────────

# Extract YAML frontmatter (content between first --- and second ---)
FRONTMATTER=""
IN_FRONTMATTER=false
FRONTMATTER_FOUND=false
LINE_NUM=0

while IFS= read -r line; do
  LINE_NUM=$((LINE_NUM + 1))

  if [ "${LINE_NUM}" -eq 1 ]; then
    if [ "${line}" = "---" ]; then
      IN_FRONTMATTER=true
      continue
    else
      die "SKILL.md does not start with YAML frontmatter (missing opening ---)"
    fi
  fi

  if [ "${IN_FRONTMATTER}" = true ]; then
    if [ "${line}" = "---" ]; then
      FRONTMATTER_FOUND=true
      break
    fi
    FRONTMATTER="${FRONTMATTER}${line}"$'\n'
  fi
done < "${SKILL_MD}"

if [ "${FRONTMATTER_FOUND}" != true ]; then
  die "SKILL.md has malformed YAML frontmatter (missing closing ---)"
fi

# ── Check 3: Required frontmatter fields ────────────────────────────────────

# Extract name from frontmatter
SKILL_NAME=$(echo "${FRONTMATTER}" | grep "^name:" | head -1 | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)

if [ -z "${SKILL_NAME}" ]; then
  die "SKILL.md frontmatter is missing required field: name"
fi

# Extract description from frontmatter
SKILL_DESC=$(echo "${FRONTMATTER}" | grep "^description:" | head -1 | sed 's/^description:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)

if [ -z "${SKILL_DESC}" ]; then
  die "SKILL.md frontmatter is missing required field: description"
fi

# ── Check 4: Name format (kebab-case, 3-50 chars) ──────────────────────────

NAME_LENGTH=${#SKILL_NAME}

if [ "${NAME_LENGTH}" -lt 3 ]; then
  die "Skill name '${SKILL_NAME}' is too short (${NAME_LENGTH} chars, minimum 3)"
fi

if [ "${NAME_LENGTH}" -gt 50 ]; then
  die "Skill name '${SKILL_NAME}' is too long (${NAME_LENGTH} chars, maximum 50)"
fi

if ! echo "${SKILL_NAME}" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
  die "Skill name '${SKILL_NAME}' is not valid kebab-case. Must match: ^[a-z0-9]+(-[a-z0-9]+)*$"
fi

# ── Check 5: No files exceed 100KB ─────────────────────────────────────────

MAX_FILE_SIZE=$((100 * 1024))  # 100KB in bytes

while IFS= read -r -d '' file; do
  FILE_SIZE=$(wc -c < "${file}" | tr -d ' ')
  if [ "${FILE_SIZE}" -gt "${MAX_FILE_SIZE}" ]; then
    REL_PATH="${file#${SKILL_DIR}/}"
    die "File '${REL_PATH}' exceeds 100KB limit (${FILE_SIZE} bytes)"
  fi
done < <(find "${SKILL_DIR}" -type f -print0)

# ── Check 6: No dangerous file paths ───────────────────────────────────────

while IFS= read -r -d '' file; do
  REL_PATH="${file#${SKILL_DIR}/}"

  # Check for path traversal (..)
  if echo "${REL_PATH}" | grep -q '\.\.'; then
    die "File path contains '..': ${REL_PATH}"
  fi

  # Check for absolute paths (starts with /)
  if echo "${REL_PATH}" | grep -q '^/'; then
    die "File path is absolute: ${REL_PATH}"
  fi
done < <(find "${SKILL_DIR}" -type f -print0)

# ── All Checks Passed ──────────────────────────────────────────────────────

echo "[validate-skill] OK: '${SKILL_NAME}' -- ${SKILL_DESC}" >&2
exit 0
