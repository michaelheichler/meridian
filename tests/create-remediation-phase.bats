#!/usr/bin/env bats

load script_contract_helper

create_source() {
  printf -v ARCHIVE '%s' "$PLANNING/milestones/$1/phases/$2"
  mkdir -p "$ARCHIVE"
  printf '%s\n' '---' 'phase: 3' 'status: issues_found' 'issues: 1' '---' \
    '### P7: Checkout' '- **Result:** issue' '- **Issue:** Checkout error' > "$ARCHIVE/03-UAT.md"
}

@test "milestone recovery preserves an active roadmap while allocating after the largest phase number" {
  create_source release-1 03-checkout
  mkdir -p "$PLANNING/phases/12-shipping" "$PLANNING/phases/scratch"
  printf '%s\n' 'User roadmap' > "$PLANNING/ROADMAP.md"
  cp "$PLANNING/ROADMAP.md" roadmap-before
  run bash "$SCRIPTS_DIR/create-remediation-phase.sh" "$PLANNING" "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'phase=13'* ]]
  cmp -s "$PLANNING/ROADMAP.md" roadmap-before
  cmp -s "$ARCHIVE/03-UAT.md" "$PLANNING/phases/13-remediate-release-1-checkout/13-SOURCE-UAT.md"
  [ "$(cat "$ARCHIVE/.remediated")" = "$PLANNING/phases/13-remediate-release-1-checkout" ]
}

@test "milestone recovery repairs a missing acknowledgement by reusing matching source metadata" {
  create_source release-1 03-checkout
  local target="$PLANNING/phases/05-remediate-release-1-checkout"
  mkdir -p "$target"
  printf '%s\n' '---' 'source_milestone: "release-1"' 'source_phase: "03-checkout"' '---' > "$target/05-CONTEXT.md"
  run bash "$SCRIPTS_DIR/create-remediation-phase.sh" "$PLANNING" "$ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phase_dir=$target"* ]]
  [ "$(cat "$ARCHIVE/.remediated")" = "$target" ]
  cmp -s "$ARCHIVE/03-UAT.md" "$target/05-SOURCE-UAT.md"
}

@test "milestone recovery restores missing projections without losing saved progress or current phase" {
  rm -rf "$PHASE"
  create_source release-1 03-checkout
  local target="$PLANNING/phases/01-remediate-release-1-checkout"
  mkdir -p "$target"
  printf '%s\n' "$target" > "$ARCHIVE/.remediated"
  printf '%s\n' '| 1 | In progress | 2 | 7 | 4 |' > "$PLANNING/ROADMAP.md"
  printf '%s\n' '**Milestone:** UAT Remediation' 'Phase: 1 of 99 (checkout)' 'Status: active' > "$PLANNING/STATE.md"
  run bash "$SCRIPTS_DIR/create-remediation-phase.sh" "$PLANNING" "$ARCHIVE"
  [ "$status" -eq 0 ]
  grep -qF '| 1 | In progress | 2 | 7 | 4 |' "$PLANNING/ROADMAP.md"
  grep -q '^Phase: 1 of 1 (' "$PLANNING/STATE.md"
  grep -qF 'Status: active' "$PLANNING/STATE.md"
  [[ "$output" == *'source_uat=none'* ]]
}

@test "milestone recovery keeps long source identities distinct even when their directory slugs share a prefix" {
  rm -rf "$PHASE"
  create_source release-with-a-long-name 03-checkout-with-many-shared-words-that-describe-the-same-feature-alpha
  local first_archive="$ARCHIVE" first_target
  local first_json
  printf '%s\n' 'First report detail' >> "$ARCHIVE/03-UAT.md"
  first_json=$(bash "$SCRIPTS_DIR/create-remediation-phase.sh" "$PLANNING" "$ARCHIVE")
  first_target=$(printf '%s\n' "$first_json" | sed -n 's/^phase_dir=//p')
  create_source release-with-a-long-name 03-checkout-with-many-shared-words-that-describe-the-same-feature-beta
  printf '%s\n' 'Second report detail' >> "$ARCHIVE/03-UAT.md"
  run bash "$SCRIPTS_DIR/create-remediation-phase.sh" "$PLANNING" "$ARCHIVE"
  [ "$status" -eq 0 ]
  local second_target
  second_target=$(printf '%s\n' "$output" | sed -n 's/^phase_dir=//p')
  [ "$first_target" != "$second_target" ]
  cmp -s "$first_archive/03-UAT.md" "$first_target/01-SOURCE-UAT.md"
  cmp -s "$ARCHIVE/03-UAT.md" "$second_target/02-SOURCE-UAT.md"
}

@test "milestone recovery reclaims an abandoned allocation lock before creating the next phase" {
  create_source release-1 03-checkout
  mkdir "$PLANNING/.create-remediation-phase.lock"
  bash -c 'printf "%s\n" "$$"' > "$PLANNING/.create-remediation-phase.lock/pid"
  run bash "$SCRIPTS_DIR/create-remediation-phase.sh" "$PLANNING" "$ARCHIVE"
  [ "$status" -eq 0 ]
  [ -s "$ARCHIVE/.remediated" ]
  [ -d "$(cat "$ARCHIVE/.remediated")" ]
  [ ! -e "$PLANNING/.create-remediation-phase.lock" ]
}
