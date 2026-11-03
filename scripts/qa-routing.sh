#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/meridian-settings.sh"

planning_dir="${1:-.meridian}"
config=$(meridian_merged_config "$planning_dir/config.json")
skip_roles=$(jq -ce 'if .qa_skip_agents == null then ["docs"] else .qa_skip_agents end | select(type == "array" and all(.[]; type == "string"))' <<< "$config")
jq -e --argjson skip_roles "$skip_roles" '
  if type != "array" or length == 0 then error("task ownership list must not be empty") else . end
  | map(
      if (.task_id | type != "string") or (.task_id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not)
        or (.owners | type != "array") or (.owners | all(.[]; type == "string" and length > 0) | not)
      then error("each task requires a stable task_id and an owners array") else . end
      | .owners |= unique
      | . as $task
      | .skip_qa = ((.owners | length) == 1 and ($skip_roles | index($task.owners[0])) != null)
      | .reason = (if .skip_qa then "QA agent skipped because the sole owner role " + .owners[0] + " matches qa_skip_agents"
          elif (.owners | length) > 1 then "Mixed owners require QA"
          elif (.owners | length) == 0 then "Unknown ownership requires QA"
          else "Owner role requires QA" end)
      | .verification_entry = (if .skip_qa then {
          id: ("qa-skip-" + .task_id), status: "WARN", description: .reason,
          evidence: ("Task " + .task_id + " retains its PLAN verification and main-session review")
        } else null end)
    )
  | {tasks: ., qa_required: any(.[]; .skip_qa | not), skip_entries: [.[] | .verification_entry | select(. != null)]}
'
