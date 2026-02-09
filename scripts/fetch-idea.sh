#!/usr/bin/env bash
# fetch-idea.sh -- Fetch and claim an open idea from the Skill Soup API.
#
# Queries for one open idea and claims it. Outputs the claimed idea JSON to stdout.
# Exits 1 if no ideas are available or the claim fails.
#
# Environment variables (set by loop.sh or export manually):
#   API_URL      - Base URL of the API (default: https://api.skillsoup.dev)
#   AUTH_TOKEN   - JWT Bearer token
#
# Usage: ./scripts/fetch-idea.sh
set -euo pipefail

API_URL="${API_URL:-https://api.skillsoup.dev}"
AUTH_TOKEN="${AUTH_TOKEN:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "[fetch-idea] ERROR: $*" >&2
  exit 1
}

api_get() {
  local path="$1"
  local retries=3
  local delay=1

  for ((attempt = 1; attempt <= retries; attempt++)); do
    local response
    local http_code

    response=$(curl -sf -w "\n%{http_code}" \
      -H "Authorization: Bearer ${AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API_URL}${path}" 2>/dev/null) || true

    http_code=$(echo "${response}" | tail -1)
    local body
    body=$(echo "${response}" | sed '$d')

    case "${http_code}" in
      200) echo "${body}"; return 0 ;;
      401) die "Unauthorized (401). Re-run setup.sh to refresh your token." ;;
      404) return 1 ;;
      5*)
        if [ "${attempt}" -lt "${retries}" ]; then
          echo "[fetch-idea] Server error (${http_code}), retrying in ${delay}s..." >&2
          sleep "${delay}"
          delay=$((delay * 2))
        else
          die "Server error (${http_code}) after ${retries} attempts."
        fi
        ;;
      *)
        if [ "${attempt}" -lt "${retries}" ]; then
          sleep "${delay}"
          delay=$((delay * 2))
        else
          die "Unexpected response (${http_code}) from GET ${path}"
        fi
        ;;
    esac
  done
}

api_patch() {
  local path="$1"
  local retries=3
  local delay=1

  for ((attempt = 1; attempt <= retries; attempt++)); do
    local response
    local http_code

    response=$(curl -sf -w "\n%{http_code}" \
      -X PATCH \
      -H "Authorization: Bearer ${AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API_URL}${path}" 2>/dev/null) || true

    http_code=$(echo "${response}" | tail -1)
    local body
    body=$(echo "${response}" | sed '$d')

    case "${http_code}" in
      200) echo "${body}"; return 0 ;;
      401) die "Unauthorized (401). Re-run setup.sh to refresh your token." ;;
      409) die "Idea already claimed (409). Skipping." ;;
      404) die "Idea not found (404)." ;;
      5*)
        if [ "${attempt}" -lt "${retries}" ]; then
          echo "[fetch-idea] Server error (${http_code}), retrying in ${delay}s..." >&2
          sleep "${delay}"
          delay=$((delay * 2))
        else
          die "Server error (${http_code}) after ${retries} attempts."
        fi
        ;;
      *)
        if [ "${attempt}" -lt "${retries}" ]; then
          sleep "${delay}"
          delay=$((delay * 2))
        else
          die "Unexpected response (${http_code}) from PATCH ${path}"
        fi
        ;;
    esac
  done
}

# ── Validate Prerequisites ──────────────────────────────────────────────────

if [ -z "${AUTH_TOKEN}" ]; then
  die "AUTH_TOKEN is not set. Run setup.sh or export AUTH_TOKEN."
fi

# ── Fetch Open Idea ─────────────────────────────────────────────────────────

IDEAS_RESPONSE=$(api_get "/api/ideas?status=open&limit=1") || true

if [ -z "${IDEAS_RESPONSE}" ]; then
  echo "[fetch-idea] No ideas available." >&2
  exit 1
fi

# The API may return an array or an object with a data array
IDEA_JSON=""
if echo "${IDEAS_RESPONSE}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  IDEA_JSON=$(echo "${IDEAS_RESPONSE}" | jq '.[0] // empty')
elif echo "${IDEAS_RESPONSE}" | jq -e '.data' >/dev/null 2>&1; then
  IDEA_JSON=$(echo "${IDEAS_RESPONSE}" | jq '.data[0] // empty')
else
  # Assume the response is a single idea object
  IDEA_JSON="${IDEAS_RESPONSE}"
fi

if [ -z "${IDEA_JSON}" ] || [ "${IDEA_JSON}" = "null" ]; then
  echo "[fetch-idea] No open ideas found." >&2
  exit 1
fi

IDEA_ID=$(echo "${IDEA_JSON}" | jq -r '.id')

if [ -z "${IDEA_ID}" ] || [ "${IDEA_ID}" = "null" ]; then
  die "Could not extract idea ID from response."
fi

echo "[fetch-idea] Found idea ${IDEA_ID}, claiming..." >&2

# ── Claim the Idea ──────────────────────────────────────────────────────────

CLAIMED_JSON=$(api_patch "/api/ideas/${IDEA_ID}/claim")

if [ -z "${CLAIMED_JSON}" ]; then
  # If the PATCH returns no body, use the original idea with updated status
  CLAIMED_JSON=$(echo "${IDEA_JSON}" | jq '.status = "claimed"')
fi

# Output the claimed idea JSON to stdout
echo "${CLAIMED_JSON}"
