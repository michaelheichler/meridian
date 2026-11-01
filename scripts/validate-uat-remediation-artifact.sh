#!/usr/bin/env bash

set -euo pipefail

ARTIFACT_TYPE="${1:-}"
ARTIFACT_PATH="${2:-}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
EXPECTED_ARTIFACT_ROUND=""
REMEDIATION_KIND=""

if [ -f "$SCRIPT_DIR/lib/uat-utils.sh" ]; then
  source "$SCRIPT_DIR/lib/uat-utils.sh"
fi
. "$SCRIPT_DIR/lib/validate-uat-remediation-paths.sh"
. "$SCRIPT_DIR/lib/validate-uat-remediation-checks.sh"

usage() {
  echo "Usage: validate-uat-remediation-artifact.sh <research|plan|summary> <absolute-artifact-path>" >&2
}

emit_failure() {
  local message="$1"

  echo "artifact_valid=false"
  echo "artifact_type=${ARTIFACT_TYPE}"
  echo "artifact_path=${ARTIFACT_PATH}"
  echo "artifact_error=${message}"
  exit 1
}

contains_regex() {
  local text="$1"
  local regex="$2"

  grep -Eq -- "$regex" <<< "$text"
}

extract_frontmatter() {
  local file="$1"

  awk '
    BEGIN { delimiter_count = 0 }
    /^---[[:space:]]*$/ {
      delimiter_count++
      if (delimiter_count == 2) exit
      next
    }
    delimiter_count == 1 { print }
  ' "$file"
}

if [ -z "$ARTIFACT_TYPE" ] || [ -z "$ARTIFACT_PATH" ]; then
  usage
  exit 1
fi

case "$ARTIFACT_TYPE" in
  research|plan|summary) ;;
  *)
    usage
    exit 1
    ;;
esac

expected_suffix=""
case "$ARTIFACT_TYPE" in
  research) expected_suffix="RESEARCH" ;;
  plan) expected_suffix="PLAN" ;;
  summary) expected_suffix="SUMMARY" ;;
esac

validate_common_path "$expected_suffix"
FRONTMATTER=$(extract_frontmatter "$ARTIFACT_PATH")
validate_frontmatter "$FRONTMATTER"
validate_frontmatter_round_matches_path "$FRONTMATTER"

case "$ARTIFACT_TYPE" in
  research) validate_research_content "$FRONTMATTER" ;;
  plan) validate_plan_content "$FRONTMATTER" ;;
  summary) validate_summary_content "$FRONTMATTER" ;;
esac

echo "artifact_valid=true"
echo "artifact_type=${ARTIFACT_TYPE}"
echo "artifact_path=${ARTIFACT_PATH}"
