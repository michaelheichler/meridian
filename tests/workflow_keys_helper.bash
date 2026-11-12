workflow_cases() {
  local reader=$1 row
  shift
  reset_case_failures
  for row in "$@"; do
    run workflow_row "$reader" "$row"
    expect_case "$reader/$row" 0
  done
  assert_no_case_failures
}

workflow_row() (
  set -e
  local reader=$1 row=$2
  mkdir -p "$BATS_TEST_TMPDIR/$reader-$row"
  cd "$BATS_TEST_TMPDIR/$reader-$row"
  trap await_git_ai EXIT
  git init -q
  mkdir -p .meridian/phases/07-release
  printf '{}\n' > .meridian/config.json
  "workflow_$reader" "$row"
)

workflow_research() {
  local row=$1 required=false forced=false effort=turbo artifact=07-RESEARCH.md
  case "$row" in
    missing) ;;
    false|balanced-off|thorough-off) printf '{"pipeline_research":false}\n' > .meridian/config.json ;;
    *) printf '{"pipeline_research":true}\n' > .meridian/config.json ;;
  esac
  case "$row" in
    balanced-off) effort=balanced; required=true ;;
    thorough-off) effort=thorough; required=true ;;
    required) effort=balanced; required=true; forced=true ;;
    turbo) required=true; forced=true ;;
    canonical) printf 'Phase findings\n' > .meridian/phases/07-release/07-RESEARCH.md ;;
    legacy)
      artifact=07-01-RESEARCH.md
      printf 'Reusable findings\n' > .meridian/phases/07-release/07-01-RESEARCH.md ;;
    multiple)
      touch .meridian/phases/07-release/07-01-RESEARCH.md .meridian/phases/07-release/07-02-RESEARCH.md
      required=true; forced=true ;;
  esac
  run bash "$SCRIPTS_DIR/pipeline-research.sh" .meridian .meridian/phases/07-release "$effort"
  [ "$status" -eq 0 ]
  [ "$output" = "research_required=$required
research_forced=$forced
research_path=.meridian/phases/07-release/$artifact" ]
}

workflow_summary() {
  local row=$1 text='People can now review the release.'
  case "$row" in
    true|false) printf '{"plain_summary":%s}\n' "$row" > .meridian/config.json ;;
    empty) text='   ' ;;
  esac
  run bash "$SCRIPTS_DIR/plain-summary.sh" .meridian <<< "$text"
  case "$row" in
    false) [ "$status" -eq 0 ]; [ -z "$output" ] ;;
    empty) [ "$status" -eq 1 ] ;;
    *) [ "$status" -eq 0 ]; [[ "$output" == '## '*$'\n\n'"$text" ]] ;;
  esac
}

workflow_qa() {
  local row=$1 tasks='[{"task_id":"guide","owners":["docs"]}]' skip=true
  case "$row" in
    explicit-empty)
      printf '{"qa_skip_agents":[]}\n' > .meridian/config.json
      skip=false ;;
    alternative)
      printf '{"qa_skip_agents":["analyst"]}\n' > .meridian/config.json
      tasks='[{"task_id":"report","owners":["analyst"]}]' ;;
    mixed)
      printf '{"qa_skip_agents":["docs","analyst"]}\n' > .meridian/config.json
      tasks='[{"task_id":"guide","owners":["docs","analyst"]}]'
      skip=false ;;
    unknown) tasks='[{"task_id":"guide","owners":[]}]'; skip=false ;;
    empty) tasks='[]' ;;
    empty-input) tasks='' ;;
    malformed-json) tasks='{' ;;
    malformed) tasks='[{"task_id":"guide","owners":"docs"}]' ;;
    all-skip) tasks='[{"task_id":"guide","owners":["docs"]},{"task_id":"help","owners":["docs"]}]' ;;
  esac
  run bash "$SCRIPTS_DIR/qa-routing.sh" .meridian <<< "$tasks"
  case "$row" in
    empty|empty-input|malformed|malformed-json) [ "$status" -gt 0 ]; [ "$status" -lt 126 ] ;;
    all-skip)
      [ "$status" -eq 0 ]
      workflow_qa_result "$skip" "$tasks"
      workflow_qa_persist ;;
    *) [ "$status" -eq 0 ]; workflow_qa_result "$skip" "$tasks" ;;
  esac
}

workflow_qa_persist() {
  local routing=$output payload
  payload=$(jq '{tier:"standard",result:"PASS",phase:"07",checks:{passed:0,failed:0,total:(.skip_entries|length)},checks_detail:.skip_entries}' <<< "$routing")
  run bash "$SCRIPTS_DIR/write-verification.sh" .meridian/phases/07-release/07-VERIFICATION.md <<< "$payload"
  [ "$status" -eq 0 ]
  jq -e --rawfile persisted .meridian/phases/07-release/07-VERIFICATION.md '
    all(.skip_entries[];
      . as $entry | [$entry.id,$entry.description,$entry.status,$entry.evidence]
      | all(.[]; . as $cell | $persisted | contains($cell)))
  ' <<< "$routing" >/dev/null
}

workflow_qa_result() {
  jq -e --argjson skip "$1" --argjson input "$2" '
    .qa_required == ($skip | not)
    and (.tasks | length) == ($input | length)
    and all(.tasks[]; .skip_qa == $skip)
    and if $skip then
      (.skip_entries | length) == ($input | length)
      and all(.tasks[];
        . as $task | .verification_entry.description == .reason
        and (.reason | contains($task.owners[0]))
        and (.verification_entry.evidence | contains($task.task_id))
        and (.verification_entry.status | length > 0))
      and .skip_entries == [.tasks[].verification_entry]
    else .skip_entries == [] end
  ' <<< "$output" >/dev/null
}
