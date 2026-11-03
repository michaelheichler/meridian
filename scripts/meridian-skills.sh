#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$SCRIPT_DIR/detect-stack.sh"
JSON_OUTPUT=0
PROJECT_ARG=""
QUERY=""
CANDIDATE=""

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: meridian-skills.sh [--json] list <project-dir>' \
    '       meridian-skills.sh [--json] refresh <project-dir>' \
    '       meridian-skills.sh [--json] search <project-dir> <query>' \
    '       meridian-skills.sh [--json] install <project-dir> <exact-candidate>' >&2
}

require_tools() {
  command -v jq >/dev/null 2>&1 || fail 'jq is required'
  [ -f "$DETECTOR" ] || fail "stack detector is unavailable: $DETECTOR"
  [ ! -L "$DETECTOR" ] || fail "stack detector must not be a symbolic link: $DETECTOR"
}

resolve_project_root() {
  local requested="$1" resolved
  [ -d "$requested" ] || fail "project directory is not readable: $requested"
  resolved=$(CDPATH='' cd -P -- "$requested" 2>/dev/null && pwd -P) \
    || fail "could not resolve project directory: $requested"
  printf '%s\n' "$resolved"
}

read_config() {
  local project_root="$1" path value
  path="$project_root/.meridian/config.json"
  [ ! -L "$path" ] || fail "configuration must not be a symbolic link: $path"
  if [ ! -e "$path" ]; then
    printf '%s\n' '{"auto_install_skills":false,"discovery_questions":true,"skill_suggestions":true}'
    return 0
  fi
  [ -f "$path" ] || fail "configuration is not a regular file: $path"
  value=$(jq -ce '
    if type != "object" then error("configuration must be an object") else . end
    | {
        auto_install_skills: (if has("auto_install_skills") then .auto_install_skills else false end),
        discovery_questions: (if has("discovery_questions") then .discovery_questions else true end),
        skill_suggestions: (if has("skill_suggestions") then .skill_suggestions else true end)
      }
    | if all(.[]; type == "boolean")
      then .
      else error("skill discovery settings must be boolean")
      end
  ' "$path" 2>/dev/null) || fail "skill discovery configuration is invalid: $path"
  printf '%s\n' "$value"
}

read_detector() {
  local project_root="$1" value
  value=$(bash "$DETECTOR" "$project_root") \
    || fail 'stack detector failed'
  jq -ce '
    type == "object"
    and (.detected_stack | type == "array" and all(.[]; type == "string"))
    and (.installed | type == "object")
    and (.installed.global | type == "array" and all(.[]; type == "string"))
    and (.installed.project | type == "array" and all(.[]; type == "string"))
    and (.recommended_skills | type == "array" and all(.[]; type == "string"))
    and (.suggestions | type == "array" and all(.[]; type == "string"))
    and (.global_skills_dir | type == "string")
  ' <<< "$value" >/dev/null 2>&1 \
    || fail 'detector output is not a valid MERIDIAN stack result'
  printf '%s\n' "$value"
}

validate_query() {
  local query="$1"
  jq -en --arg query "$query" '
    ($query | length) > 0
    and ($query | length) <= 200
    and ($query | test("[\u0000-\u001f\u007f]") | not)
  ' >/dev/null 2>&1 || fail 'search query must be 1 to 200 printable characters'
}

result_filter_defs() {
  cat <<'JQ'
def strings: map(select(length > 0)) | unique | sort;
def mode($count; $enabled; $questions):
  if ($enabled and $questions) | not then "disabled"
  elif $count == 0 then "none"
  elif $count == 1 then "single"
  elif $count <= 4 then "bounded"
  else "freeform"
  end;
JQ
}

result_filter_body() {
  cat <<'JQ'
($detector.suggestions | strings) as $all_candidates
| (if $config.skill_suggestions then $all_candidates else [] end) as $enabled_candidates
| (if $operation == "search"
    then ($query | ascii_downcase) as $needle
      | [$enabled_candidates[] | select((ascii_downcase | contains($needle)))]
    else $enabled_candidates
    end) as $candidates
| {
    schema_version: 1,
    operation: $operation,
    config: $config,
    detected_stack: ($detector.detected_stack | strings),
    installed: {
      global: ($detector.installed.global | strings),
      project: ($detector.installed.project | strings)
    },
    candidates: $candidates,
    candidate_count: ($candidates | length),
    question_mode: mode(
      ($candidates | length);
      $config.skill_suggestions;
      $config.discovery_questions
    )
  }
| if $operation == "search" then . + {query: $query} else . end
JQ
}

build_result() {
  local operation="$1" config="$2" detector="$3" query="${4:-}"
  jq -cnS \
    --arg operation "$operation" \
    --arg query "$query" \
    --argjson config "$config" \
    --argjson detector "$detector" "$(result_filter_defs)
$(result_filter_body)"
}

safe_cell() {
  jq -r '
    gsub("\r\n|\r|\n"; "?")
    | gsub("[\u0000-\u001f\u007f]"; "?")
    | gsub("\\|"; "\\|")
  '
}

print_rows() {
  local values="$1" scope="$2" count=0 value value_json
  while IFS= read -r value_json; do
    [ -n "$value_json" ] || continue
    value=$(safe_cell <<< "$value_json")
    printf '| %s | %s |\n' "$scope" "$value"
    count=$((count + 1))
  done < <(jq -c '.[]' <<< "$values")
  if [ "$count" -eq 0 ]; then
    printf '| %s | None |\n' "$scope"
  fi
}

print_settings() {
  local result="$1" stack stack_json
  stack_json=$(jq -c '.detected_stack | if length == 0 then "None" else join(", ") end' <<< "$result")
  stack=$(safe_cell <<< "$stack_json")
  printf '%s\n' 'MERIDIAN Skills' ''
  printf '| Setting | Value |\n|---|---|\n'
  printf '| Operation | %s |\n' "$(jq -r '.operation' <<< "$result")"
  printf '| Skill suggestions | %s |\n' "$(jq -r '.config.skill_suggestions' <<< "$result")"
  printf '| Discovery questions | %s |\n' "$(jq -r '.config.discovery_questions' <<< "$result")"
  printf '| Automatic installation requested | %s |\n' "$(jq -r '.config.auto_install_skills' <<< "$result")"
  printf '| Detected stack | %s |\n' "$stack"
}

print_candidates() {
  local candidates="$1" index=0 value value_json
  printf '\n%s\n' 'Discovered candidates'
  printf '| Number | Skill |\n|---:|---|\n'
  while IFS= read -r value_json; do
    [ -n "$value_json" ] || continue
    index=$((index + 1))
    value=$(safe_cell <<< "$value_json")
    printf '| %d | %s |\n' "$index" "$value"
  done < <(jq -c '.[]' <<< "$candidates")
  if [ "$index" -eq 0 ]; then
    printf '| 0 | None |\n'
  fi
}

print_decision() {
  local result="$1" mode enabled auto
  mode=$(jq -r '.question_mode' <<< "$result")
  enabled=$(jq -r '.config.skill_suggestions' <<< "$result")
  auto=$(jq -r '.config.auto_install_skills' <<< "$result")
  case "$mode" in
    disabled)
      if [ "$enabled" != true ]; then
        printf '%s\n' 'Skill suggestions are disabled. No installation decision is requested.'
      else
        printf '%s\n' 'Discovery questions are disabled. No installation decision is requested.'
      fi
      ;;
    none) printf '%s\n' 'No installable candidate was discovered. Use search with a stack-related term.' ;;
    single) printf '%s\n' 'One candidate is ready for a bounded install or skip decision in the main session.' ;;
    bounded) printf '%s\n' 'Candidates are ready for sequential install or skip decisions in the main session.' ;;
    freeform) printf '%s\n' 'More than four candidates require a validated numbered selection in the main session.' ;;
  esac
  if [ "$auto" = true ]; then
    printf '%s\n' 'Automatic installation is configured, but MERIDIAN still requires explicit main-session consent.'
  fi
}

print_human() {
  local result="$1"
  print_settings "$result"
  printf '\n%s\n' 'Installed skills'
  printf '| Scope | Skill |\n|---|---|\n'
  print_rows "$(jq -c '.installed.project' <<< "$result")" project
  print_rows "$(jq -c '.installed.global' <<< "$result")" global
  print_candidates "$(jq -c '.candidates' <<< "$result")"
  printf '\n'
  print_decision "$result"
}

emit_result() {
  local result="$1"
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    jq -cS . <<< "$result"
  else
    print_human "$result"
  fi
}

emit_install_block() {
  local candidate="$1" result
  result=$(jq -cnS --arg candidate "$candidate" '{
    candidate: $candidate,
    operation: "install",
    reason: "external_installation_not_authorized",
    status: "blocked"
  }')
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' \
      'MERIDIAN Skills installation handoff' \
      '' \
      "Candidate: $candidate" \
      'Status: blocked' \
      'Reason: installation needs an external registry or network mutation.' \
      'MERIDIAN validated the candidate but did not install it.'
  fi
  return 3
}

parse_operation_args() {
  local operation="$1"
  shift
  case "$operation" in
    list|refresh)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      PROJECT_ARG="$1"
      ;;
    search)
      [ "$#" -eq 2 ] || { usage; exit 2; }
      PROJECT_ARG="$1"
      QUERY="$2"
      validate_query "$QUERY"
      ;;
    install)
      [ "$#" -eq 2 ] || { usage; exit 2; }
      PROJECT_ARG="$1"
      CANDIDATE="$2"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main() {
  local operation project_root config detector result
  if [ "${1:-}" = '--json' ]; then
    JSON_OUTPUT=1
    shift
  fi
  operation="${1:-}"
  [ -n "$operation" ] || { usage; exit 2; }
  shift
  parse_operation_args "$operation" "$@"

  require_tools
  project_root=$(resolve_project_root "$PROJECT_ARG")
  config=$(read_config "$project_root")
  detector=$(read_detector "$project_root")
  result=$(build_result "$operation" "$config" "$detector" "$QUERY")

  if [ "$operation" = install ]; then
    jq -e --arg candidate "$CANDIDATE" '.candidates | index($candidate) != null' \
      <<< "$result" >/dev/null \
      || fail "skill is not an exact discovered candidate: $CANDIDATE"
    emit_install_block "$CANDIDATE"
    return $?
  fi
  emit_result "$result"
}

main "$@"
