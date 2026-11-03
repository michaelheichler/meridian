#!/bin/bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -u
. "$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)/lib/debug-logging.sh" 2>/dev/null || true
debug_logging_gate file-guard.sh PreToolUse 2>/dev/null || true
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
PLANNING_DIR_OVERRIDE="${LBWC_PLANNING_DIR:-}"

command -v jq >/dev/null 2>&1 || {
  echo "Blocked: jq not available, cannot validate file write" >&2
  exit 2
}
. "$SCRIPT_DIR/lib/lbwc-control-root.sh" 2>/dev/null || {
  echo "Blocked: control root resolver unavailable" >&2
  exit 2
}
. "$SCRIPT_DIR/lib/tmux-agent-context.sh" 2>/dev/null || {
  echo "Blocked: tmux agent context library unavailable" >&2
  exit 2
}

INPUT=$(cat 2>/dev/null) || { echo "Blocked: unable to read file guard input" >&2; exit 2; }
[ -n "$INPUT" ] || exit 0

json_fields() {
  jq -j --arg source "$1" --arg identifier "${AGENT_IDENTIFIER:-}" \
    --arg expected_root "${expected_root:-}" --argjson entry "${AGENT_ENTRY:-null}" \
    -f "$SCRIPT_DIR/lib/file-guard-fields.jq" 2>/dev/null
}

read_field() {
  local field_value=''
  IFS= read -r -d '' field_value || true
  while [[ "$field_value" = *$'\n' ]]; do field_value=${field_value%$'\n'}; done
  printf -v "$1" '%s' "$field_value"
}

TOOL_NAME="" FILE_PATH="" HOOK_CWD="" AGENT_IDENTIFIER=""
{
  read_field TOOL_NAME
  read_field FILE_PATH
  read_field HOOK_CWD
  read_field AGENT_IDENTIFIER
} < <(printf '%s' "$INPUT" | json_fields hook)
[ -n "$FILE_PATH" ] || exit 0
if tmux_agent_context; then
  case "$FILE_PATH" in
    *.runtime-snapshot.json*) echo 'Blocked: tmux agent cannot write a frozen runtime snapshot' >&2; exit 2 ;;
  esac
fi
case "$FILE_PATH" in
  *$'\n'*) echo "Blocked: newline in file path" >&2; exit 2 ;;
  ..|../*|*/..|*/../*) echo "Blocked: path traversal in file path ($FILE_PATH)" >&2; exit 2 ;;
esac

[ -n "$HOOK_CWD" ] || HOOK_CWD="$PWD"
HOOK_CWD=$(CDPATH='' cd -- "$HOOK_CWD" 2>/dev/null && pwd -P || printf '%s' "$HOOK_CWD")
case "$FILE_PATH" in
  [/]*) RESOLVED_PATH="$FILE_PATH" ;;
  *) RESOLVED_PATH="$HOOK_CWD/$FILE_PATH" ;;
esac

CONTROL_ROOT=""
if [ -n "$PLANNING_DIR_OVERRIDE" ]; then
  CONTROL_ROOT=$(lbwc_control_root_validate "$PLANNING_DIR_OVERRIDE" 1 2>/dev/null || true)
else
  CONTROL_ROOT=$(lbwc_resolve_control_root "" "" "$HOOK_CWD" 2>/dev/null || true)
fi
if [ -n "$CONTROL_ROOT" ]; then
  MANIFEST=$(lbwc_control_root_manifest_path "$CONTROL_ROOT" 2>/dev/null || true)
else
  MANIFEST=""
fi

canonical_directory() {
  local CDPATH=''
  cd -- "$1" 2>/dev/null && pwd -P
}

canonical_existing_parent() {
  local directory="$1" parent
  directory=$(dirname "$directory")
  while [ ! -d "$directory" ]; do
    [ -L "$directory" ] && return 1
    parent=$(dirname "$directory")
    [ "$parent" != "$directory" ] || return 1
    directory="$parent"
  done
  canonical_directory "$directory"
}

canonical_existing_path() {
  local path="$1" parent target symlink_hops=0
  while [ -L "$path" ]; do
    symlink_hops=$((symlink_hops + 1))
    [ "$symlink_hops" -le 40 ] || return 1
    parent=$(canonical_existing_parent "$path") || return 1
    target=$(readlink "$path") || return 1
    if [[ "$target" = /* ]]; then
      path="$target"
    else
      path="$parent/$target"
    fi
  done
  [ -e "$path" ] || return 1
  if [ -d "$path" ]; then
    canonical_directory "$path"
  else
    parent=$(canonical_existing_parent "$path") || return 1
    printf '%s/%s\n' "$parent" "$(basename "$path")"
  fi
}

path_is_within_root() {
  [ "$1" = "$2" ] && return 0
  [[ "$1" = "$2/"* ]]
}

worker_root_matches_project() {
  local project_root="$1" worker_root="$2" project_common worker_common record listed_root control_project
  [ "$worker_root" = "$project_root" ] && return 0
  path_is_within_root "$CONTROL_ROOT" "$worker_root" && return 1
  case "$worker_root" in
    "$project_root/.claude/worktrees/"*/*) return 1 ;;
    "$project_root/.claude/worktrees/"?*) ;;
    "$CONTROL_ROOT/.runtime/worker-worktrees/$AGENT_IDENTIFIER")
      case "$AGENT_IDENTIFIER" in ''|*/*) return 1 ;; esac
      control_project=$(lbwc_control_root_project_root "$CONTROL_ROOT") || return 1
      [ "$control_project" = "$project_root" ] || return 1
      ;;
    *) return 1 ;;
  esac
  project_common=$(git -C "$project_root" rev-parse --git-common-dir 2>/dev/null) || return 1
  worker_common=$(git -C "$worker_root" rev-parse --git-common-dir 2>/dev/null) || return 1
  [[ "$project_common" = /* ]] || project_common="$project_root/$project_common"
  [[ "$worker_common" = /* ]] || worker_common="$worker_root/$worker_common"
  project_common=$(canonical_directory "$project_common") || return 1
  worker_common=$(canonical_directory "$worker_common") || return 1
  [ "$worker_common" = "$project_common" ] || return 1
  while IFS= read -r -d '' record; do
    [[ "$record" = 'worktree '* ]] || continue
    listed_root=$(canonical_directory "${record#worktree }") || continue
    [ "$listed_root" = "$worker_root" ] && return 0
  done < <(git -C "$project_root" worktree list --porcelain -z 2>/dev/null)
  return 1
}

agent_write_capability_allows() {
  local identifier="$2" expected_root actual_root candidate_path candidate_parent candidate_target allowance contract_path contract relative_path schema_version capability_index capability_kind capability_path capability_relative contract_valid
  schema_version="$ENTRY_SCHEMA"
  expected_root="$ENTRY_ROOT"
  [ -n "$expected_root" ] || return 1
  expected_root=$(canonical_directory "$expected_root") || return 1
  actual_root=$(canonical_directory "$HOOK_CWD") || return 1
  worker_root_matches_project "$expected_root" "$actual_root" || return 2
  candidate_path="$actual_root/$FILE_PATH"
  [[ "$FILE_PATH" == /* ]] && candidate_path="$FILE_PATH"
  case "$candidate_path" in
    "$actual_root"/*) relative_path=${candidate_path#"$actual_root"/} ;;
    *) return 5 ;;
  esac
  case "$relative_path" in
    *.runtime-snapshot.json*|config/subagent-critical-execution.txt|config/destructive-commands.txt|scripts/*guard*|scripts/task-contract.sh|scripts/agent-lifecycle.sh|.lbwc-planning/.agent-manifest.json|.lbwc-planning/.contracts|.lbwc-planning/.contracts/*|.claude/agents|.claude/agents/*) return 7 ;;
  esac
  contract_path="$ENTRY_CONTRACT"
  if [ -n "$contract_path" ] || [[ "$identifier" == lbwc-* ]]; then
    [ -n "$contract_path" ] || return 6
    contract=$(bash "$SCRIPT_DIR/task-contract.sh" verify "$contract_path" "$expected_root" 2>/dev/null) || return 6
    contract_valid=false
    {
      read_field contract_valid
      read_field schema_version
    } < <(printf '%s' "$contract" | json_fields contract)
    [ "$contract_valid" = true ] || return 6
  fi
  if [ "$schema_version" = "3" ]; then
    [ "$CAPABILITIES_VALID" = true ] || return 3
    capability_index=0
    while [ "$capability_index" -lt "$CAPABILITY_COUNT" ]; do
      capability_kind="${CAPABILITY_KINDS[$capability_index]}"
      capability_path="${CAPABILITY_PATHS[$capability_index]}"
      capability_index=$((capability_index + 1))
      case "$capability_kind" in
        file)
          capability_relative="$relative_path"
          [ "$candidate_path" = "$actual_root/$capability_path" ] || continue
          ;;
        directory)
          if [ "$capability_path" = "." ]; then
            capability_relative="$relative_path"
          else
            case "$relative_path" in
              "$capability_path"|"$capability_path"/*) capability_relative="$relative_path" ;;
              *) continue ;;
            esac
          fi
          ;;
        *) return 6 ;;
      esac
      candidate_parent=$(canonical_existing_parent "$candidate_path") || return 5
      path_is_within_root "$candidate_parent" "$actual_root" || return 5
      if [ -L "$candidate_path" ]; then
        candidate_target=$(canonical_existing_path "$candidate_path") || return 5
        path_is_within_root "$candidate_target" "$actual_root" || return 5
      fi
      case "$capability_relative" in
        .lbwc-planning|.lbwc-planning/*|.temporary-agent-runfiles|.temporary-agent-runfiles/*|.claude/agents|.claude/agents/*|.git|.git/*|.env|.env.*|*/.env|*/.env.*|*.pem|*.key|*.cert|*.p12|*.pfx|*/credentials.json|*/secrets.json|*/service-account.json|credentials.json|secrets.json|service-account.json|*.runtime-snapshot.json*|config/subagent-critical-execution.txt|config/destructive-commands.txt|scripts/*guard*|scripts/task-contract.sh|scripts/agent-lifecycle.sh) return 7 ;;
      esac
      return 0
    done
    return 4
  fi
  [ "$ALLOWANCES_VALID" = true ] || return 3
  for allowance in ${WRITE_ALLOWANCES[@]+"${WRITE_ALLOWANCES[@]}"}; do
    if [ "$candidate_path" = "$actual_root/$allowance" ]; then
      candidate_parent=$(canonical_existing_parent "$candidate_path") || return 5
      path_is_within_root "$candidate_parent" "$actual_root" || return 5
      if [ -L "$candidate_path" ]; then
        candidate_target=$(canonical_existing_path "$candidate_path") || return 5
        path_is_within_root "$candidate_target" "$actual_root" || return 5
      fi
      return 0
    fi
  done
  return 4
}

path_in_planning() {
  local planning_dir="${CONTROL_ROOT:-${PLANNING_DIR_OVERRIDE:-.lbwc-planning}}"
  if [ -n "$CONTROL_ROOT" ]; then
    case "$1" in
      "$CONTROL_ROOT"|"$CONTROL_ROOT"/*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  if [[ "$planning_dir" != /* ]]; then
    planning_dir="$HOOK_CWD/${planning_dir#./}"
  fi
  case "$1" in
    "$planning_dir"|"$planning_dir"/*|*"/$planning_dir"|*"/$planning_dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

path_is_agent_definition() {
  case "$1" in
    .claude/agents|.claude/agents/*|*/.claude/agents|*/.claude/agents/*) return 0 ;;
    *) return 1 ;;
  esac
}

path_is_doc_file() {
  case "$1" in
    *.md|*.mdx|*.rst|*.txt) return 0 ;;
  esac
  path_in_planning "$1"
}

path_is_test_file() {
  local base
  base=$(basename -- "$1")
  case "$1" in
    */test/*|*/tests/*) return 0 ;;
  esac
  case "$base" in
    test_*|*_test.*|*.test.*|*.spec.*) return 0 ;;
    *) return 1 ;;
  esac
}

AGENT_ENTRY="" AGENT_ROLE="" OPEN_PAIR=0 ENTRY_SCHEMA=2 ENTRY_ROOT="" ENTRY_CONTRACT=""
CAPABILITIES_VALID=false ALLOWANCES_VALID=false CAPABILITY_COUNT=0
CAPABILITY_KINDS=() CAPABILITY_PATHS=() WRITE_ALLOWANCES=()
if [ -f "$MANIFEST" ]; then
  {
    read_field AGENT_ENTRY
    read_field AGENT_ROLE
    read_field OPEN_PAIR
    read_field ENTRY_SCHEMA
    read_field ENTRY_ROOT
    read_field ENTRY_CONTRACT
    read_field CAPABILITIES_VALID
    read_field ALLOWANCES_VALID
    read_field CAPABILITY_COUNT
    case "$CAPABILITY_COUNT" in ''|*[!0-9]*) CAPABILITY_COUNT=0 ;; esac
    CAPABILITY_INDEX=0
    while [ "$CAPABILITY_INDEX" -lt "$CAPABILITY_COUNT" ]; do
      read_field CAPABILITY_KIND
      read_field CAPABILITY_PATH
      CAPABILITY_KINDS+=("$CAPABILITY_KIND")
      CAPABILITY_PATHS+=("$CAPABILITY_PATH")
      CAPABILITY_INDEX=$((CAPABILITY_INDEX + 1))
    done
    while IFS= read -r -d '' ALLOWANCE; do
      WRITE_ALLOWANCES+=("$ALLOWANCE")
    done
  } < <(json_fields manifest < "$MANIFEST")
fi

if [ -n "$AGENT_ENTRY" ]; then
  agent_write_capability_allows "$AGENT_ENTRY" "$AGENT_IDENTIFIER"
  capability_status=$?
  case "$capability_status" in
    0) ;;
    2)
      echo "Blocked: generated workers may write only from the manifest primary workspace" >&2
      exit 2
      ;;
    3)
      echo "Blocked: worker '$AGENT_IDENTIFIER' has no assigned write allowance" >&2
      exit 2
      ;;
    5)
      echo "Blocked: path escapes the canonical primary root" >&2
      exit 2
      ;;
    6)
      echo "Blocked: worker '$AGENT_IDENTIFIER' contract is missing, mismatched, stale, or outside allowance" >&2
      exit 2
      ;;
    7)
      echo "Blocked: generated workers cannot write LBWC policy, guard, contract, manifest, lifecycle, or agent-definition paths" >&2
      exit 2
      ;;
    *)
      echo "Blocked: path is outside worker '$AGENT_IDENTIFIER' assigned write allowance" >&2
      exit 2
      ;;
  esac
elif [ -n "$AGENT_IDENTIFIER" ] && [[ "$AGENT_IDENTIFIER" == lbwc-* ]]; then
  echo "Blocked: worker '$AGENT_IDENTIFIER' manifest capability could not be resolved" >&2
  exit 2
fi

case "$AGENT_ROLE" in
  architect|lead|scout)
    path_in_planning "$RESOLVED_PATH" || {
      echo "Blocked: role '$AGENT_ROLE' can only write under the control root" >&2
      exit 2
    }
    ;;
  docs)
    path_is_doc_file "$RESOLVED_PATH" || {
      echo "Blocked: role 'docs' can only write documentation files" >&2
      exit 2
    }
    ;;
  qa-author|test-dev)
    path_is_test_file "$RESOLVED_PATH" || {
      echo "Blocked: role '$AGENT_ROLE' can only write test files" >&2
      exit 2
    }
    ;;
esac

if [ -z "$AGENT_ROLE" ] && [ "$TOOL_NAME" != "" ] && [ -f "$MANIFEST" ]; then
  case "${OPEN_PAIR:-0}" in ''|*[!0-9]*) OPEN_PAIR=0 ;; esac
  if [ "$OPEN_PAIR" -gt 0 ] 2>/dev/null; then
    path_is_doc_file "$RESOLVED_PATH" || path_is_agent_definition "$RESOLVED_PATH" || {
      echo "Blocked: main session has a spawned pair/trio open, delegate product writes to it instead of writing directly" >&2
      exit 2
    }
  fi
fi

exit 0
