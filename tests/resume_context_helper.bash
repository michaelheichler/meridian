seed_resume_repo() {
  git config user.name 'Resume Fixture'
  git config user.email resume@example.invalid
  printf 'original\n' > queue.txt
  git add queue.txt
  git commit -qm 'Initialize queue'
  printf '{}\n' > "$MERIDIAN_PLANNING_DIR/config.json"
}

append_resume_entry() {
  bash "$SCRIPTS_DIR/explorer-journal.sh" append --trigger pause \
    --request 'Keep queue recovery working' --next 'Verify retry handling'
}

resume_output() {
  bash "$SCRIPTS_DIR/resume-context.sh"
}

unchanged_history() {
  seed_resume_repo
  append_resume_entry
  bash "$SCRIPTS_DIR/explorer-journal.sh" current > "$BATS_TEST_TMPDIR/expected"
  resume_output > "$BATS_TEST_TMPDIR/actual"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/actual"
}

advanced_history() {
  seed_resume_repo
  append_resume_entry
  local sequence head
  for sequence in 1 2 3; do
    git commit --allow-empty -qm "Queue change $sequence"
  done
  head=$(git rev-parse --short HEAD)
  resume_output > "$BATS_TEST_TMPDIR/actual"
  grep -Eq 'HEAD moved by 3 commit' "$BATS_TEST_TMPDIR/actual"
  grep -Fq "$head Queue change 3" "$BATS_TEST_TMPDIR/actual"
  grep -Eq '^[0-9a-f]+ Queue change 2$' "$BATS_TEST_TMPDIR/actual"
  grep -Eq '^[0-9a-f]+ Queue change 1$' "$BATS_TEST_TMPDIR/actual"
  run grep -E '^[0-9a-f]+ Initialize queue$' "$BATS_TEST_TMPDIR/actual"
  [ "$status" -eq 1 ]
}

fallback_history() {
  local kind="$1"
  seed_resume_repo
  case "$kind" in
    unknown) printf '## fixture pause\n\n### HEAD\n\n    ffffffffffffffffffffffffffffffffffffffff\n' > "$MERIDIAN_PLANNING_DIR/EXPLORER-JOURNAL.md" ;;
    missing) printf '## fixture pause\n\n### Original request\n\n    Continue recovery\n' > "$MERIDIAN_PLANNING_DIR/EXPLORER-JOURNAL.md" ;;
    divergent)
      append_resume_entry
      git checkout -q --orphan rewritten
      git commit -qm 'Independent queue history'
      ;;
    absent) : ;;
  esac
  printf 'pending retry update\n' >> queue.txt
  git diff --stat > "$BATS_TEST_TMPDIR/diff"
  resume_output > "$BATS_TEST_TMPDIR/actual"
  grep -F -f "$BATS_TEST_TMPDIR/diff" "$BATS_TEST_TMPDIR/actual" > "$BATS_TEST_TMPDIR/retained-diff"
  cmp "$BATS_TEST_TMPDIR/diff" "$BATS_TEST_TMPDIR/retained-diff"
  [ -s "$BATS_TEST_TMPDIR/diff" ]
  case "$kind" in
    unknown|missing) grep -Eqi 'journal HEAD.*(unknown|unreachable)' "$BATS_TEST_TMPDIR/actual" ;;
    divergent) grep -Eqi '(unreachable|history.*changed|diverg)' "$BATS_TEST_TMPDIR/actual" ;;
    absent) grep -Eqi 'no .*journal' "$BATS_TEST_TMPDIR/actual" ;;
  esac
  run grep -E 'HEAD moved by|^[0-9a-f]+ Independent queue history' "$BATS_TEST_TMPDIR/actual"
  [ "$status" -eq 1 ]
}

unknown_history() { fallback_history unknown; }
missing_history() { fallback_history missing; }
divergent_history() { fallback_history divergent; }
absent_journal() { fallback_history absent; }

seed_phase_evidence() {
  local phase directory
  printf 'Phase: 2\nPlans: 1/2\n' > "$MERIDIAN_PLANNING_DIR/STATE.md"
  printf '# Queue service\n' > "$MERIDIAN_PLANNING_DIR/PROJECT.md"
  printf 'Continue queue retry verification.\n' > "$MERIDIAN_PLANNING_DIR/RESUME.md"
  printf '### Phase 1: setup\n### Phase 2: queue\n### Phase 3: release\n' > "$MERIDIAN_PLANNING_DIR/ROADMAP.md"
  for phase in 01-setup 02-queue 03-release; do
    directory="$MERIDIAN_PLANNING_DIR/phases/$phase"
    mkdir -p "$directory"
    printf '# Plan\n%03500d\n' 0 > "$directory/01-PLAN.md"
    printf '# Plan\n%03500d\n' 0 > "$directory/02-PLAN.md"
  done
  printf '%s\n' '---' 'status: complete' '---' '# Verified setup' > "$MERIDIAN_PLANNING_DIR/phases/01-setup/01-SUMMARY.md"
  cp "$MERIDIAN_PLANNING_DIR/phases/01-setup/01-SUMMARY.md" "$MERIDIAN_PLANNING_DIR/phases/01-setup/02-SUMMARY.md"
  printf '%s\n' '---' 'status: complete' '---' '# Verified first queue plan' > "$MERIDIAN_PLANNING_DIR/phases/02-queue/01-SUMMARY.md"
  mkdir -p "$MERIDIAN_PLANNING_DIR/milestones/archived/phases/02-queue"
  cp "$MERIDIAN_PLANNING_DIR/phases/02-queue/01-PLAN.md" "$MERIDIAN_PLANNING_DIR/milestones/archived/phases/02-queue/01-PLAN.md"
}

check_evidence_selection() {
  local directory="$MERIDIAN_PLANNING_DIR/phases/02-queue" file bytes
  append_resume_entry
  find "$directory" -maxdepth 1 -type f \( -name '*-PLAN.md' -o -name '*-SUMMARY.md' -o -name PLAN.md -o -name SUMMARY.md \) | LC_ALL=C sort > "$BATS_TEST_TMPDIR/expected"
  resume_output > "$BATS_TEST_TMPDIR/actual"
  sed -n 's/^active_phase_file=//p' "$BATS_TEST_TMPDIR/actual" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/selected"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/selected"
  [ -s "$BATS_TEST_TMPDIR/selected" ]
  cat "$MERIDIAN_PLANNING_DIR/PROJECT.md" "$MERIDIAN_PLANNING_DIR/STATE.md" "$MERIDIAN_PLANNING_DIR/ROADMAP.md" "$MERIDIAN_PLANNING_DIR/RESUME.md" "$BATS_TEST_TMPDIR/actual" > "$BATS_TEST_TMPDIR/context"
  while IFS= read -r file; do
    cat "$file" >> "$BATS_TEST_TMPDIR/context"
  done < "$BATS_TEST_TMPDIR/selected"
  bytes=$(wc -c < "$BATS_TEST_TMPDIR/context")
  [ "$bytes" -lt 16000 ]
}

numbered_evidence() {
  seed_resume_repo
  seed_phase_evidence
  check_evidence_selection
}

legacy_evidence() {
  seed_resume_repo
  seed_phase_evidence
  mv "$MERIDIAN_PLANNING_DIR/phases/02-queue/01-PLAN.md" "$MERIDIAN_PLANNING_DIR/phases/02-queue/PLAN.md"
  mv "$MERIDIAN_PLANNING_DIR/phases/02-queue/01-SUMMARY.md" "$MERIDIAN_PLANNING_DIR/phases/02-queue/SUMMARY.md"
  check_evidence_selection
}

custom_planning() {
  export MERIDIAN_PLANNING_DIR="$PWD/custom-state"
  mkdir -p "$MERIDIAN_PLANNING_DIR"
  numbered_evidence
}

discovered_planning() {
  export MERIDIAN_PLANNING_DIR="$PWD/.meridian"
  mkdir -p "$MERIDIAN_PLANNING_DIR"
  seed_resume_repo
  seed_phase_evidence
  mkdir -p nested/child
  cd nested/child
  unset MERIDIAN_PLANNING_DIR
  export MERIDIAN_PLANNING_DIR="$(git rev-parse --show-toplevel)/.meridian"
  append_resume_entry
  unset MERIDIAN_PLANNING_DIR
  resume_output > "$BATS_TEST_TMPDIR/actual"
  sed -n 's/^active_phase_file=//p' "$BATS_TEST_TMPDIR/actual" | LC_ALL=C sort > "$BATS_TEST_TMPDIR/selected"
  find "$(git rev-parse --show-toplevel)/.meridian/phases/02-queue" -maxdepth 1 -type f | LC_ALL=C sort > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/selected"
}

clean_consistency() {
  seed_resume_repo
  seed_phase_evidence
  append_resume_entry
  resume_output > "$BATS_TEST_TMPDIR/actual"
  run grep -E 'state_consistency=|^DRIFT' "$BATS_TEST_TMPDIR/actual"
  [ "$status" -eq 1 ]
}

drift_consistency() {
  seed_resume_repo
  seed_phase_evidence
  printf 'Phase: 2\nPlans: 0/9\n' > "$MERIDIAN_PLANNING_DIR/STATE.md"
  bash "$SCRIPTS_DIR/verify-state-consistency.sh" > "$BATS_TEST_TMPDIR/findings" || [ "$?" -eq 1 ]
  append_resume_entry
  resume_output > "$BATS_TEST_TMPDIR/actual"
  grep -q '^DRIFT' "$BATS_TEST_TMPDIR/findings"
  grep '^DRIFT' "$BATS_TEST_TMPDIR/actual" > "$BATS_TEST_TMPDIR/retained"
  cmp "$BATS_TEST_TMPDIR/findings" "$BATS_TEST_TMPDIR/retained"
}

compaction_context() {
  local role="$1" context
  seed_resume_repo
  seed_phase_evidence
  append_resume_entry
  bash "$SCRIPTS_DIR/worktree-agent-map.sh" set "$role" "$PWD/worker-tree"
  printf '{"agent_type":"%s","name":"%s"}\n' "$role" "$role" > "$BATS_TEST_TMPDIR/input"
  bash "$SCRIPTS_DIR/post-compact.sh" < "$BATS_TEST_TMPDIR/input" > "$BATS_TEST_TMPDIR/compacted"
  context=$(jq -er '.hookSpecificOutput.additionalContext' "$BATS_TEST_TMPDIR/compacted")
  [[ "$context" == *'Keep queue recovery working'* ]]
  [[ "$context" == *'RESUME.md'* ]]
  [[ "$context" == *'active_phase_file='* ]]
  case "$role" in
    python-engineer)
      [[ "$context" == *"$role"* ]]
      [[ "$context" == *"$PWD/worker-tree"* ]]
      ;;
    unknown) [[ "$context" == *'ORCHESTRATOR RESUME'* ]] ;;
  esac
}

worker_compaction() { compaction_context python-engineer; }
orchestrator_compaction() { compaction_context unknown; }

failed_phase_detection() {
  seed_resume_repo
  export TMPDIR="$BATS_TEST_TMPDIR/nonexistent"
  run resume_output
  [ "$status" -ne 0 ]
  [[ "$output" != *'active_phase_file='* ]]
}

failed_compaction() {
  seed_resume_repo
  export TMPDIR="$BATS_TEST_TMPDIR/nonexistent"
  run bash "$SCRIPTS_DIR/post-compact.sh" <<< '{}'
  [ "$status" -eq 0 ]
  local context
  context=$(printf '%s' "$output" | jq -er '.hookSpecificOutput.additionalContext')
  [[ "$context" == *'failed'* ]]
  [[ "$context" == *'RESUME.md'* ]]
}
