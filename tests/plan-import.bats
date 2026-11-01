#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  SCRIPT="$SCRIPTS_DIR/plan-import.sh"
  mkdir -p "$TEST_TEMP_DIR/gsd"
  cp -R "$PROJECT_ROOT/tests/fixtures/import/gsd/.planning" "$TEST_TEMP_DIR/gsd/.planning"
  GSD_SOURCE="$TEST_TEMP_DIR/gsd/.planning"
  cd "$TEST_TEMP_DIR"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

fresh_project() {
  PROJECT="$TEST_TEMP_DIR/$1"
  PLANNING="$PROJECT/.lbwc-planning"
  mkdir -p "$PROJECT"
}

stage_gsd() {
  run bash "$SCRIPT" stage --adapter gsd --source "$GSD_SOURCE" --project-root "$PROJECT" --import-id "$1"
  STAGE="$PROJECT/.temporary-agent-runfiles/imports/$1"
  expect_status "stage-$1" 0
}

promote_staged() {
  local args artifact
  args=(--project-root "$PROJECT" --stage "$STAGE")
  while IFS= read -r artifact; do
    args+=(--artifact "$artifact")
  done < <(jq -r '.additions[]' "$STAGE/preview.json")
  run bash "$SCRIPT" promote "${args[@]}"
}

digest_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

@test "plan-import normalize: gsd and markdown adapters emit tagged IR within the caps" {
  local source number

  run bash "$SCRIPT" normalize --adapter gsd --source "$GSD_SOURCE" --output "$TEST_TEMP_DIR/gsd-ir.json"
  expect_status gsd-ir 0
  expect_jq gsd-ir "$TEST_TEMP_DIR/gsd-ir.json" '
    .schema_version == 1 and
    .source.system == "gsd" and
    .source.trust_tier == "verified-adapter" and
    .source.root == ".planning" and
    .source.gsd_version == "3" and
    .project.name == "Fixture Project" and
    .phases[0].status == "complete" and
    (.provenance | any(.field == "project.name" and .extraction_method == "markdown-heading")) and
    (.provenance | any(.field == "phases[0].status" and .extraction_method == "summary-file-presence"))'

  source="$TEST_TEMP_DIR/markdown"
  mkdir -p "$source"
  for number in $(seq 1 65); do
    printf '# Generic %s\n' "$number" > "$source/plan-$number.md"
  done
  dd if=/dev/zero of="$source/oversized.md" bs=1048577 count=1 2>/dev/null
  run bash "$SCRIPT" normalize --adapter markdown --source "$source" --output "$TEST_TEMP_DIR/markdown-ir.json"
  expect_status markdown-caps 0
  expect_jq markdown-caps "$TEST_TEMP_DIR/markdown-ir.json" '
    .source.trust_tier == "unverified-markdown" and
    (.plans | length) == 64 and
    (.source.limits.max_files == 64) and
    (.source.limits.max_file_bytes == 1048576) and
    (.source.limits.max_total_bytes == 8388608) and
    (.plans | all(.status == null and .depends_on == null)) and
    (.warnings | any(contains("file-count-cap"))) and
    (.warnings | any(contains("file-size-cap")))'

  source="$TEST_TEMP_DIR/markdown-bytes"
  mkdir -p "$source"
  for number in $(seq 1 9); do
    dd if=/dev/zero of="$source/plan-$number.md" bs=1000000 count=1 2>/dev/null
  done
  run bash "$SCRIPT" normalize --adapter markdown --source "$source" --output "$TEST_TEMP_DIR/markdown-bytes-ir.json"
  expect_status markdown-total-bytes 0
  expect_jq markdown-total-bytes "$TEST_TEMP_DIR/markdown-bytes-ir.json" '(.source.skipped_files | any(.reason == "total-byte-cap")) and (.warnings | any(contains("total-byte-cap")))'

  assert_no_case_failures
}

@test "plan-import usage: rejects missing commands and arguments" {
  run bash "$SCRIPT"
  expect_case no-command 2 "Usage: plan-import.sh"

  run bash "$SCRIPT" bogus
  expect_case unknown-command 2 "Usage: plan-import.sh"

  run bash "$SCRIPT" --help
  expect_case help-flag 2 "Usage: plan-import.sh"

  run bash "$SCRIPT" normalize --adapter gsd
  expect_case normalize-missing-args 1 "normalize requires --adapter, --source, and --output"

  run bash "$SCRIPT" stage --adapter gsd --source "$GSD_SOURCE" --bogus
  expect_case unknown-option 1 "unknown option: --bogus"

  run bash "$SCRIPT" promote --project-root "$TEST_TEMP_DIR"
  expect_case promote-missing-stage 1 "promote requires --project-root and --stage"

  assert_no_case_failures
}

@test "plan-import digest: follows hidden source files" {
  local first second

  run bash "$SCRIPT" digest --source "$GSD_SOURCE" --output "$TEST_TEMP_DIR/first.json"
  expect_status digest-first 0
  run bash "$SCRIPT" digest --source "$GSD_SOURCE" --output "$TEST_TEMP_DIR/again.json"
  expect_status digest-again 0
  [ "$(jq -r '.digest' "$TEST_TEMP_DIR/first.json")" = "$(jq -r '.digest' "$TEST_TEMP_DIR/again.json")" ] \
    || record_case_failure digest-stable "unchanged source produced two digests"

  printf '%s\n' 'changed hidden source content' > "$GSD_SOURCE/.source-marker"
  run bash "$SCRIPT" digest --source "$GSD_SOURCE" --output "$TEST_TEMP_DIR/second.json"
  expect_status digest-second 0
  first=$(jq -r '.digest' "$TEST_TEMP_DIR/first.json")
  second=$(jq -r '.digest' "$TEST_TEMP_DIR/second.json")
  [ "$first" != "$second" ] || record_case_failure digest-hidden-change "hidden file change left the digest unchanged"

  assert_no_case_failures
}

@test "generate-gsd-index: indexes a GSD tree without modifying it" {
  local before after

  before=$(find "$GSD_SOURCE" -type f -print | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')
  run bash "$SCRIPTS_DIR/generate-gsd-index.sh" "$GSD_SOURCE"
  expect_status gsd-index 0
  expect_jq_output gsd-index '(.gsd_version == "3") and (.quick_paths.roadmap | endswith("/ROADMAP.md"))'
  after=$(find "$GSD_SOURCE" -type f -print | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')
  [ "$before" = "$after" ] || record_case_failure gsd-index "source tree digest changed"
  expect_no_path gsd-index "$GSD_SOURCE/INDEX.json"

  assert_no_case_failures
}

@test "plan-import stage builds a validated tree, leaves canonical files alone, and fails closed on an invalid adapter output" {
  local before

  fresh_project canonical-kept
  mkdir -p "$PLANNING"
  printf '%s\n' '# Existing canonical project' > "$PLANNING/PROJECT.md"
  before=$(digest_of "$PLANNING/PROJECT.md")
  stage_gsd import-one
  expect_path stage-tree "$STAGE/ir.json"
  expect_path stage-tree "$STAGE/preview.json"
  expect_path stage-tree "$STAGE/tree/.lbwc-planning/PROJECT.md"
  run bash "$SCRIPT" validate-stage --project-root "$PROJECT" --stage "$STAGE"
  expect_status validate-stage 0
  expect_same_digest canonical-kept "$PLANNING/PROJECT.md" "$before"
  expect_no_path canonical-kept "$PLANNING/imports/import-one/manifest.json"

  fresh_project single-markdown
  printf '# Solo Plan\n\nBody text.\n' > "$TEST_TEMP_DIR/solo.md"
  run bash "$SCRIPT" stage --adapter markdown --source "$TEST_TEMP_DIR/solo.md" --project-root "$PROJECT" --import-id md-file
  STAGE="$PROJECT/.temporary-agent-runfiles/imports/md-file"
  expect_status single-markdown 0
  expect_jq single-markdown "$STAGE/preview.json" '
    .source.trust_tier == "unverified-markdown" and
    (.additions | index(".lbwc-planning/imported-markdown/solo.md") != null) and
    (.unknowns | any(. == "solo.md"))'
  expect_file_line single-markdown "$STAGE/tree/.lbwc-planning/imported-markdown/solo.md" 'unverified generic Markdown import'
  expect_file_line single-markdown "$STAGE/tree/.lbwc-planning/imported-markdown/solo.md" 'Body text\.'

  fresh_project semantic-preview
  mkdir -p "$PLANNING"
  printf -- '- [x] **REQ-01**: Import the project without changing the source\n- [ ] **REQ-02**: Preserve source provenance\n- [ ] **REQ-99**: Existing only\n' > "$PLANNING/REQUIREMENTS.md"
  stage_gsd semantic
  expect_jq semantic-preview "$STAGE/preview.json" '
    ([.additions[], .overlaps[], .conflicts[].artifact, .unknowns[], .skipped[].path] | all(startswith("/") | not)) and
    (.conflicts | length == 1) and
    (.conflicts[0].artifact == ".lbwc-planning/REQUIREMENTS.md") and
    (.conflicts[0].detail.removed_ids == ["REQ-99"]) and
    (.conflicts[0].detail.changed_statuses | length == 2) and
    (.conflicts[0].source_digest | test("^[0-9a-f]{64}$")) and
    (.conflicts[0].destination_digest | test("^[0-9a-f]{64}$"))'

  fresh_project bad-adapter
  mkdir -p "$TEST_TEMP_DIR/not-gsd"
  run bash "$SCRIPT" stage --adapter gsd --source "$TEST_TEMP_DIR/not-gsd" --project-root "$PROJECT" --import-id bad-import
  expect_status bad-adapter 1
  expect_no_path bad-adapter "$PLANNING"

  assert_no_case_failures
}

@test "plan-import reimport: reports an unchanged source and allows a fresh stage" {
  fresh_project reimport-staged
  stage_gsd first-import
  run bash "$SCRIPT" reimport --source "$GSD_SOURCE" --project-root "$PROJECT"
  expect_status reimport-staged 0
  expect_jq_output reimport-staged '.status == "unchanged" and .previous_import_id == "first-import"'

  fresh_project reimport-promoted
  stage_gsd re-one
  promote_staged
  expect_status reimport-promote 0
  run bash "$SCRIPT" reimport --source "$GSD_SOURCE" --project-root "$PROJECT"
  expect_status reimport-promoted 0
  expect_jq_output reimport-promoted '.status == "unchanged" and .previous_import_id == "re-one"'
  run bash "$SCRIPT" stage --adapter gsd --source "$GSD_SOURCE" --project-root "$PROJECT" --import-id re-two
  expect_status reimport-restage 0

  assert_no_case_failures
}

@test "plan-import promote writes template-valid artifacts, config and provenance, refuses unsafe artifacts and drifted sources, and restores every destination when promotion fails" {
  local promoted before_project before_state

  fresh_project promote-full
  stage_gsd full-import
  promote_staged
  expect_status promote-full 0
  promoted="$PLANNING"

  expect_file_line content "$promoted/PROJECT.md" '^# Fixture Project$'
  expect_file_line content "$promoted/PROJECT.md" '\*\*Core value:\*\*'
  expect_file_line content "$promoted/STATE.md" '## Current Phase'
  expect_file_line content "$promoted/STATE.md" '## Key Decisions'
  expect_file_line content "$promoted/ROADMAP.md" '### Phase 1: foundation'
  expect_file_line content "$promoted/REQUIREMENTS.md" '^- \[x\] \*\*REQ-02\*\*'
  expect_file_line content "$promoted/phases/01-foundation/01-01-PLAN.md" '^phase: 1$'
  expect_file_line content "$promoted/phases/01-foundation/01-01-PLAN.md" '<objective>'
  expect_file_line content "$promoted/phases/01-foundation/01-01-PLAN.md" 'Implement the import boundary\.'

  expect_path provenance "$promoted/imports/full-import/ir.json"
  expect_path provenance "$promoted/imports/full-import/preview.json"
  expect_jq provenance "$promoted/imports/full-import/manifest.json" '.status == "promoted"'

  run bash "$SCRIPTS_DIR/lbwc-config.sh" validate-config-json < "$promoted/config.json"
  expect_status config-valid 0
  [ "$(jq -S . "$promoted/config.json")" = "$(bash "$SCRIPTS_DIR/lbwc-config.sh" default-config | jq -S .)" ] \
    || record_case_failure config-defaults "config.json differs from init defaults"
  expect_jq config-shape "$promoted/config.json" '.schema_version == 1 and (.routing.profiles | keys | sort == ["balanced","quality","turbo"])'
  run bash "$SCRIPTS_DIR/lbwc-config.sh" validate "$promoted"
  expect_status config-validate 0

  run bash -c 'cd "$1" && LBWC_PLANNING_DIR="$2" bash "$3"' _ "$PROJECT" "$promoted" "$SCRIPTS_DIR/verify-state-consistency.sh"
  expect_case state-consistency 0 "state_consistency=ok"

  fresh_project guard-artifacts
  stage_gsd guard-import
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE"
  expect_status no-artifacts 1
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" --artifact '.lbwc-planning/../config.json'
  expect_status artifact-dotdot-config 1
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" --artifact '../outside.md'
  expect_status artifact-parent 1
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" --artifact '/absolute.md'
  expect_status artifact-absolute 1
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" --artifact '.lbwc-planning/config.json.md'
  expect_status artifact-near-allowlist 1
  expect_no_path guard-artifacts "$PLANNING/config.json"

  fresh_project source-drift
  stage_gsd drift-import
  printf '%s\n' 'mutated after staging' > "$GSD_SOURCE/.source-marker"
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" --artifact .lbwc-planning/PROJECT.md
  expect_case source-drift 1 "source changed after staging"
  expect_no_path source-drift "$PLANNING/PROJECT.md"
  expect_no_path source-drift "$PLANNING/imports/drift-import/manifest.json"

  fresh_project fail-after-one
  mkdir -p "$PLANNING"
  printf '%s\n' '# Old project' > "$PLANNING/PROJECT.md"
  printf '%s\n' '# Old roadmap' > "$PLANNING/ROADMAP.md"
  stage_gsd rollback-import
  run env LBWC_IMPORT_FAIL_AFTER=1 bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" \
    --artifact .lbwc-planning/PROJECT.md --artifact .lbwc-planning/ROADMAP.md
  expect_case fail-after-one 1 "promotion failed after artifact .lbwc-planning/PROJECT.md"
  expect_file_line fail-after-one "$PLANNING/PROJECT.md" '^# Old project$'
  expect_file_line fail-after-one "$PLANNING/ROADMAP.md" '^# Old roadmap$'

  fresh_project fail-after-two
  mkdir -p "$PLANNING"
  printf '%s\n' '# Canonical project' > "$PLANNING/PROJECT.md"
  printf '%s\n' '# Canonical state' > "$PLANNING/STATE.md"
  before_project=$(digest_of "$PLANNING/PROJECT.md")
  before_state=$(digest_of "$PLANNING/STATE.md")
  stage_gsd fail-import
  run env LBWC_IMPORT_FAIL_AFTER=2 bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" \
    --artifact .lbwc-planning/PROJECT.md --artifact .lbwc-planning/STATE.md --artifact .lbwc-planning/REQUIREMENTS.md
  expect_status fail-after-two 1
  expect_same_digest fail-after-two "$PLANNING/PROJECT.md" "$before_project"
  expect_same_digest fail-after-two "$PLANNING/STATE.md" "$before_state"
  expect_no_path fail-after-two "$PLANNING/REQUIREMENTS.md"
  expect_no_path fail-after-two "$PLANNING/imports/fail-import/manifest.json"

  fresh_project validation-fails
  mkdir -p "$PLANNING"
  printf '%s\n' '# Canonical project' > "$PLANNING/PROJECT.md"
  printf '%s\n' '# Canonical state' > "$PLANNING/STATE.md"
  before_project=$(digest_of "$PLANNING/PROJECT.md")
  before_state=$(digest_of "$PLANNING/STATE.md")
  stage_gsd validate-fail-import
  run env LBWC_IMPORT_FAIL_VALIDATION=1 bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" \
    --artifact .lbwc-planning/PROJECT.md --artifact .lbwc-planning/STATE.md \
    --artifact .lbwc-planning/REQUIREMENTS.md --artifact .lbwc-planning/config.json
  expect_case validation-fails 1 "post-promotion validation failed"
  expect_same_digest validation-fails "$PLANNING/PROJECT.md" "$before_project"
  expect_same_digest validation-fails "$PLANNING/STATE.md" "$before_state"
  expect_no_path validation-fails "$PLANNING/REQUIREMENTS.md"
  expect_no_path validation-fails "$PLANNING/config.json"
  expect_no_path validation-fails "$PLANNING/imports/validate-fail-import/manifest.json"

  fresh_project partial-without-config
  stage_gsd partial-import
  run bash "$SCRIPT" promote --project-root "$PROJECT" --stage "$STAGE" --artifact .lbwc-planning/PROJECT.md
  expect_case partial-without-config 1 "post-promotion validation failed"
  expect_no_path partial-without-config "$PLANNING/imports/partial-import/manifest.json"
  expect_no_path partial-without-config "$PLANNING"

  assert_no_case_failures
}
