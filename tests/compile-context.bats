#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  create_test_config
  mkdir -p "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase"
  cat > "$TEST_TEMP_DIR/.lbwc-planning/ROADMAP.md" <<'EOF'
## Phase 1: Test Phase
**Goal:** Test goal
**Success:** Tests pass
**Reqs:** REQ-01
EOF
  cat > "$TEST_TEMP_DIR/.lbwc-planning/REQUIREMENTS.md" <<'EOF'
- [ ] REQ-01: Test requirement
EOF
  cat > "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase/PLAN.md" <<'EOF'
## Tasks
- [ ] TASK-01: Do something
EOF
}

teardown() {
  teardown_temp_dir
}

@test "compile-context: default configuration skips session telemetry" {
  cd "$TEST_TEMP_DIR"

  run bash -x "$SCRIPTS_DIR/compile-context.sh" 01 dev .lbwc-planning/phases

  [ "$status" -eq 0 ]
  [[ "$output" == *"V3_METRICS_ENABLED=false"* ]]
  [[ "$output" != *"session-telemetry.py"* ]]
  [ ! -e "$TEST_TEMP_DIR/.lbwc-planning/telemetry/session.jsonl" ]
}

@test "compile-context: project metrics opt-in records session telemetry" {
  printf '%s\n' '{"metrics":true}' > "$TEST_TEMP_DIR/.lbwc-planning/config.json"
  cd "$TEST_TEMP_DIR"

  run bash -x "$SCRIPTS_DIR/compile-context.sh" 01 dev .lbwc-planning/phases

  [ "$status" -eq 0 ]
  [[ "$output" == *"V3_METRICS_ENABLED=true"* ]]
  [[ "$output" == *"session-telemetry.py"* ]]
  run python3 -c 'import json,sys; records=[json.loads(line) for line in open(sys.argv[1])]; assert records[-1]["event"]=="command"; assert records[-1]["outcome"]=="success"' "$TEST_TEMP_DIR/.lbwc-planning/telemetry/session.jsonl"
  [ "$status" -eq 0 ]
}

seed_full_planning() {
  local planning="$TEST_TEMP_DIR/.lbwc-planning"
  printf '%s\n' '## Phase 1: Test Phase' '**Goal:** Ship the widget' '**Success:** Widget renders' '**Reqs:** REQ-01' '## Phase 2: Next Phase' > "$planning/ROADMAP.md"
  printf '%s\n' '- [ ] REQ-01: Phase requirement' '- [ ] REQ-02: Other requirement' > "$planning/REQUIREMENTS.md"
  printf '%s\n' '## Key Decisions' '- chose sqlite' '## Recent Activity' '- ran the scout' '## Other' 'ignored' > "$planning/STATE.md"
  printf '%s\n' '{"conventions":[{"tag":"style","rule":"use tabs"}]}' > "$planning/conventions.json"
  mkdir -p "$planning/codebase"
  printf 'meta\n' > "$planning/codebase/META.md"
  printf 'arch\n' > "$planning/codebase/ARCHITECTURE.md"
  printf 'research body\n' > "$planning/phases/01-test-phase/01-RESEARCH.md"
}

check_role() {
  local label="$1" role="$2" present="$3" absent="$4" marker content
  cd "$TEST_TEMP_DIR"
  run bash "$SCRIPTS_DIR/compile-context.sh" 01 "$role" .lbwc-planning/phases ${5:+"$5"}
  [ "$status" -eq 0 ] || { echo "[$label] exit $status: $output" >&2; return 1; }
  content=$(cat "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase/.context-${role}.md")
  while IFS= read -r marker; do
    [ -z "$marker" ] && continue
    [[ "$content" == *"$marker"* ]] || { echo "[$label] missing '$marker' in context:"$'\n'"$content" >&2; return 1; }
  done <<< "$present"
  while IFS= read -r marker; do
    [ -z "$marker" ] && continue
    [[ "$content" != *"$marker"* ]] || { echo "[$label] forbidden '$marker' in context:"$'\n'"$content" >&2; return 1; }
  done <<< "$absent"
}

@test "compile-context: every role emits its own heading and section set" {
  seed_full_planning
  local retired=$'### Available Skills\n### Mandatory Skill Activation'

  check_role "lead sections" lead \
    $'## Phase 01 Context (Compiled)\n### Goal\nShip the widget\n### Success Criteria\nWidget renders\n### Requirements (REQ-01)\nREQ-01: Phase requirement\n### Active Decisions\n- chose sqlite' \
    $'### Conventions\n'"Verification Context"$'\n'"REQ-02: Other"$'\n'"$retired"
  check_role "dev sections" dev \
    $'## Phase 01 Context\n### Goal\nShip the widget\n### Conventions\n- [style] use tabs\n### Research Findings\nresearch body' \
    $'### Success Criteria\n### Requirements\n### Active Decisions\n'"$retired"
  check_role "qa sections" qa \
    $'## Phase 01 Verification Context\n### Success Criteria\n### Requirements to Verify\nREQ-01: Phase requirement\n### Conventions to Check' \
    $'### Research Findings\n### Active Decisions\n'"$retired"
  check_role "scout sections" scout \
    $'## Phase 01 Research Context\n### Requirements (REQ-01)\n### Conventions\n### Research Findings' \
    $'### Active Decisions\n### Recent Activity\n'"$retired"
  check_role "debugger sections" debugger \
    $'## Phase 01 Debug Context\n### Recent Activity\n- ran the scout\n### Conventions' \
    $'ignored\n'"$retired"
  check_role "architect sections" architect \
    $'## Phase 01 Architecture Context\n### Full Requirements\nREQ-02: Other requirement\n### Conventions\n### Research Findings' \
    $'### Requirements (\n### Recent Activity\n'"$retired"
}

@test "compile-context: lead reports hidden requirements and swaps research for the codebase map when research is missing" {
  seed_full_planning
  check_role "lead with research" lead $'### Research Findings' $'### Codebase Map Available'

  rm "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase/01-RESEARCH.md"
  check_role "lead no research" lead \
    $'(1 other requirements exist for other phases -- not shown)\n### Codebase Map Available\nRead ARCHITECTURE.md first' \
    $'### Research Findings'
}

@test "compile-context: dev embeds the active plan only when a plan path is given" {
  seed_full_planning
  local plan="$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase/PLAN.md"

  check_role "dev with plan" dev $'### Active Plan\nTASK-01: Do something' "" "$plan"
  check_role "dev without plan" dev "" $'### Active Plan'
}

@test "compile-context: debugger activity falls back to None without STATE.md" {
  seed_full_planning
  rm "$TEST_TEMP_DIR/.lbwc-planning/STATE.md"

  check_role "debugger no state" debugger $'### Recent Activity\nNone\n### Conventions' $'ran the scout'
}

@test "compile-context: architect states when no requirements file exists" {
  seed_full_planning
  rm "$TEST_TEMP_DIR/.lbwc-planning/REQUIREMENTS.md"

  check_role "architect no requirements" architect $'### Full Requirements\nNo requirements file found' $'REQ-01:'
}

@test "compile-context: caveman directive adds the commit note for dev and the review note for qa only" {
  seed_full_planning
  printf '%s\n' '{"caveman_style":"full","caveman_commit":true,"caveman_review":true}' > "$TEST_TEMP_DIR/.lbwc-planning/config.json"

  check_role "dev caveman" dev $'### Caveman Language (full)\ncaveman-commit.md' $'caveman-review.md'
  check_role "qa caveman" qa $'### Caveman Language (full)\ncaveman-review.md' $'caveman-commit.md'
  check_role "scout caveman" scout $'### Caveman Language (full)' $'caveman-commit.md\ncaveman-review.md'
}

@test "compile-context: unknown role exits non-zero and lists the valid roles" {
  cd "$TEST_TEMP_DIR"

  run bash "$SCRIPTS_DIR/compile-context.sh" 01 janitor .lbwc-planning/phases

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown role: janitor. Valid roles: lead, dev, qa, scout, debugger, architect"* ]]
}

check_roadmap_phase() {
  local label="$1" phase="$2" roadmap="$3" present="$4" absent="$5" dir marker content
  local planning="$TEST_TEMP_DIR/.lbwc-planning"
  dir="$planning/phases/0${phase}-case"
  mkdir -p "$dir"
  printf '%s\n' "$roadmap" > "$planning/ROADMAP.md"
  printf '%s\n' '- [ ] REQ-01: First requirement' '- [ ] REQ-02: Second requirement' '- [ ] REQ-03: Third requirement' > "$planning/REQUIREMENTS.md"
  cd "$TEST_TEMP_DIR"
  run bash "$SCRIPTS_DIR/compile-context.sh" "0${phase}" lead .lbwc-planning/phases
  [ "$status" -eq 0 ] || { echo "[$label] exit $status: $output" >&2; return 1; }
  content=$(cat "$dir/.context-lead.md")
  while IFS= read -r marker; do
    [ -z "$marker" ] && continue
    [[ "$content" == *"$marker"* ]] || { echo "[$label] missing '$marker' in context:"$'\n'"$content" >&2; return 1; }
  done <<< "$present"
  while IFS= read -r marker; do
    [ -z "$marker" ] && continue
    [[ "$content" != *"$marker"* ]] || { echo "[$label] forbidden '$marker' in context:"$'\n'"$content" >&2; return 1; }
  done <<< "$absent"
}

@test "compile-context: the only roadmap phase keeps its Reqs line" {
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase"

  check_roadmap_phase "single phase, Reqs last" 1 \
    $'## Phase 1: Only\n**Goal:** Ship the widget\n**Success:** Widget renders\n**Reqs:** REQ-01' \
    $'### Requirements (REQ-01)\nREQ-01: First requirement' ""
}

@test "compile-context: the last of several roadmap phases keeps its Reqs line" {
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase"

  check_roadmap_phase "two phases, Reqs last in phase 2" 2 \
    $'## Phase 1: First\n**Goal:** Early goal\n**Reqs:** REQ-01\n## Phase 2: Second\n**Goal:** Ship the widget\n**Success:** Widget renders\n**Reqs:** REQ-02' \
    $'### Requirements (REQ-02)\nREQ-02: Second requirement' $'REQ-01:'
}

@test "compile-context: the last roadmap phase keeps its Success line" {
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase"

  check_roadmap_phase "last phase, Success last" 2 \
    $'## Phase 1: First\n**Reqs:** REQ-01\n## Phase 2: Second\n**Goal:** Ship the widget\n**Reqs:** REQ-02\n**Success:** Widget renders' \
    $'### Success Criteria\nWidget renders' ""
}

@test "compile-context: the last roadmap phase keeps its Goal line" {
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase"

  check_roadmap_phase "last phase, Goal last" 2 \
    $'## Phase 1: First\n**Reqs:** REQ-01\n## Phase 2: Second\n**Success:** Widget renders\n**Reqs:** REQ-02\n**Goal:** Ship the widget' \
    $'### Goal\nShip the widget' ""
}

@test "compile-context: a middle roadmap phase excludes the next phase heading and content" {
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning/phases/01-test-phase"

  check_roadmap_phase "middle phase" 2 \
    $'## Phase 1: First\n**Reqs:** REQ-01\n## Phase 2: Second\n**Goal:** Second goal\n**Success:** Second success\n**Reqs:** REQ-02\n## Phase 3: Third\n**Goal:** Third goal\n**Reqs:** REQ-03' \
    $'### Goal\nSecond goal\n### Success Criteria\nSecond success\n### Requirements (REQ-02)\nREQ-02: Second requirement' \
    $'Third goal\nREQ-03:\nREQ-01:'
}
