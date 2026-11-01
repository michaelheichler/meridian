#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  SCRIPT="$SCRIPTS_DIR/extract-skill-follow-up-files.sh"
}

teardown() {
  teardown_temp_dir
}

row_dir() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/project" "$dir/home" "$dir/cfg"
  printf '%s\n' "$dir"
}

phys() {
  (cd "$1" && pwd -P)
}

skill_body() {
  printf '%s\n' '---' 'name: fixture-skill' 'description: Fixture skill' '---' '' '# Fixture Skill' '' '## References' '' "$@"
}

make_skill() {
  local base_dir=$1 skill_name=$2 body=$3 rel_path
  shift 3
  mkdir -p "$base_dir/$skill_name/references"
  printf '%s\n' "$body" > "$base_dir/$skill_name/SKILL.md"
  for rel_path in "$@"; do
    mkdir -p "$(dirname "$base_dir/$skill_name/$rel_path")"
    printf '# %s\n' "$rel_path" > "$base_dir/$skill_name/$rel_path"
  done
}

make_standard_skill() {
  make_skill "$1" "$2" "$(skill_body '- [First](references/first.md)' '- [Second](references/second.md)')" \
    references/first.md references/second.md
}

run_extract() {
  local row=$1
  shift
  run env HOME="$row/home" CLAUDE_CONFIG_DIR="$row/cfg" bash "$SCRIPT" --project-dir "$row/project" "$@"
}

run_extract_no_cfg() {
  local row=$1
  shift
  run env -u CLAUDE_CONFIG_DIR HOME="$row/home" bash "$SCRIPT" --project-dir "$row/project" "$@"
}

@test "extract-skill-follow-up-files emits deduplicated absolute paths of in-skill link targets for every listed skill and drops links that leave the skill" {
  local row project cfg home first_count

  row=$(row_dir project-skill)
  project=$(phys "$row/project")
  make_skill "$row/project/.claude/skills" swiftdata "$(skill_body \
    '- [First](references/first.md)' '- [Second](references/second.md)' '- [Anchor](#local-anchor)' \
    '- [External](https://example.com/reference.md)' '- [Mail](mailto:a@example.com)' \
    '- [Rooted](/etc/hosts)' '- [Missing](references/missing.md)')" \
    references/first.md references/second.md
  run_extract "$row" swiftdata
  expect_case "project-skill-exact-block" 0 ""
  [ "$output" = "$(printf '%s\n' '<skill_follow_up_files>' 'Skill: swiftdata' \
    "- $project/.claude/skills/swiftdata/references/first.md" \
    "- $project/.claude/skills/swiftdata/references/second.md" '' '</skill_follow_up_files>')" ] \
    || record_case_failure "project-skill-exact-block" "unexpected block=[$output]"

  row=$(row_dir project-over-global)
  project=$(phys "$row/project")
  cfg=$(phys "$row/cfg")
  make_standard_skill "$row/cfg/skills" swiftdata
  make_standard_skill "$row/project/.claude/skills" swiftdata
  run_extract "$row" swiftdata
  expect_case "project-over-global" 0 "$project/.claude/skills/swiftdata/references/first.md"
  expect_output_lacks "project-over-global-no-global" "$cfg/skills/swiftdata"

  row=$(row_dir config-dir)
  cfg=$(phys "$row/cfg")
  make_standard_skill "$row/cfg/skills" find-docs
  run_extract "$row" find-docs
  expect_case "config-dir-fallback" 0 "Skill: find-docs"
  expect_output_has "config-dir-fallback-path" "$cfg/skills/find-docs/references/first.md"

  row=$(row_dir home-config-claude-code)
  home=$(phys "$row/home")
  make_standard_skill "$row/home/.config/claude-code/skills" find-docs
  run_extract_no_cfg "$row" find-docs
  expect_case "home-config-claude-code" 0 "Skill: find-docs"
  expect_output_has "home-config-claude-code-path" "$home/.config/claude-code/skills/find-docs/references/first.md"

  row=$(row_dir home-claude)
  home=$(phys "$row/home")
  make_standard_skill "$row/home/.claude/skills" find-docs
  run_extract_no_cfg "$row" find-docs
  expect_case "home-claude" 0 "$home/.claude/skills/find-docs/references/first.md"

  row=$(row_dir whitespace-list)
  make_standard_skill "$row/project/.claude/skills" swiftdata
  make_standard_skill "$row/project/.claude/skills" swift-testing
  run_extract "$row" "swiftdata swift-testing"
  expect_case "whitespace-list" 0 "Skill: swiftdata"
  expect_output_has "whitespace-list-second" "Skill: swift-testing"

  row=$(row_dir comma-list)
  make_standard_skill "$row/project/.claude/skills" swiftdata
  make_standard_skill "$row/project/.claude/skills" swift-testing
  run_extract "$row" "swiftdata,swift-testing" absent-skill
  expect_case "comma-list" 0 "Skill: swiftdata"
  expect_output_has "comma-list-second" "Skill: swift-testing"
  expect_output_lacks "comma-list-absent-skill-skipped" "absent-skill"

  row=$(row_dir separator)
  make_standard_skill "$row/project/.claude/skills" swiftdata
  run_extract "$row" -- swiftdata
  expect_case "double-dash-separator" 0 "Skill: swiftdata"

  row=$(row_dir traversal-token-in-list)
  project=$(phys "$row/project")
  make_standard_skill "$row/project/.claude/skills" swiftdata
  make_standard_skill "$row/project/.agents/skills" swiftdata
  run_extract "$row" "swiftdata ../../.agents/skills/swiftdata"
  expect_case "traversal-token-in-list" 0 "$project/.claude/skills/swiftdata/references/first.md"
  expect_output_lacks "traversal-token-in-list-no-agents" "$project/.agents/skills"

  row=$(row_dir normalize-dedupe)
  project=$(phys "$row/project")
  make_skill "$row/project/.claude/skills" swiftdata "$(skill_body \
    '- [First](references/first.md)' '- [Duplicate First](./references/first.md)' \
    '- [Normalized](docs/../references/second.md)' '- [Fragment](references/third.md#section)')" \
    references/first.md references/second.md references/third.md docs/.keep
  run_extract "$row" swiftdata
  expect_case "normalize-dedupe" 0 "$project/.claude/skills/swiftdata/references/first.md"
  expect_output_has "normalized-link" "$project/.claude/skills/swiftdata/references/second.md"
  expect_output_has "fragment-stripped" "$project/.claude/skills/swiftdata/references/third.md"
  first_count=$(printf '%s\n' "$output" | grep -cFx -- "- $project/.claude/skills/swiftdata/references/first.md")
  [ "$first_count" -eq 1 ] || record_case_failure "dedupe-count" "first.md listed $first_count times"

  row=$(row_dir project-escape-link)
  project=$(phys "$row/project")
  make_skill "$row/project/.claude/skills" swiftdata "$(skill_body \
    '- [Safe](references/first.md)' '- [Escape](../other-skill/references/secret.md)')" references/first.md
  make_standard_skill "$row/project/.claude/skills" other-skill
  printf '# secret\n' > "$row/project/.claude/skills/other-skill/references/secret.md"
  run_extract "$row" swiftdata
  expect_case "project-escape-link" 0 "$project/.claude/skills/swiftdata/references/first.md"
  expect_output_lacks "project-escape-link-secret" "other-skill"

  row=$(row_dir global-escape-link)
  cfg=$(phys "$row/cfg")
  make_skill "$row/cfg/skills" find-docs "$(skill_body \
    '- [Safe](references/first.md)' '- [Normalized](docs/../references/second.md)' \
    '- [Escape](../other-skill/references/secret.md)')" references/first.md references/second.md docs/.keep
  make_standard_skill "$row/cfg/skills" other-skill
  printf '# secret\n' > "$row/cfg/skills/other-skill/references/secret.md"
  run_extract "$row" find-docs
  expect_case "global-escape-link" 0 "$cfg/skills/find-docs/references/first.md"
  expect_output_has "global-escape-link-normalized" "$cfg/skills/find-docs/references/second.md"
  expect_output_lacks "global-escape-link-secret" "other-skill"

  row=$(row_dir project-symlink)
  project=$(phys "$row/project")
  make_skill "$row/project/.claude/skills" swiftdata "$(skill_body \
    '- [Safe](references/first.md)' '- [Symlink Escape](references/linked-outside.md)')" references/first.md
  printf '# secret\n' > "$row/outside.md"
  ln -s "$row/outside.md" "$row/project/.claude/skills/swiftdata/references/linked-outside.md"
  run_extract "$row" swiftdata
  expect_case "project-symlink" 0 "$project/.claude/skills/swiftdata/references/first.md"
  expect_output_lacks "project-symlink-dropped" "linked-outside.md"

  row=$(row_dir global-symlink)
  cfg=$(phys "$row/cfg")
  make_skill "$row/cfg/skills" find-docs "$(skill_body \
    '- [Safe](references/first.md)' '- [Symlink Escape](references/linked-outside.md)')" references/first.md
  printf '# secret\n' > "$row/outside.md"
  ln -s "$row/outside.md" "$row/cfg/skills/find-docs/references/linked-outside.md"
  run_extract "$row" find-docs
  expect_case "global-symlink" 0 "$cfg/skills/find-docs/references/first.md"
  expect_output_lacks "global-symlink-dropped" "linked-outside.md"

  assert_no_case_failures
}

@test "extract-skill-follow-up-files stays silent for unresolvable or unsafe skills and handles help and option errors" {
  local row

  row=$(row_dir lookalike-roots)
  make_standard_skill "$row/project/.agents/skills" swiftdata
  make_standard_skill "$row/project/.pi/skills" swiftdata
  make_standard_skill "$row/home/.agents/skills" swiftdata
  run_extract "$row" swiftdata
  expect_case_silent "lookalike-roots" 0

  row=$(row_dir traversal-project-lookalike)
  mkdir -p "$row/project/.claude/skills"
  make_standard_skill "$row/project/.agents/skills" swiftdata
  make_standard_skill "$row/project/.pi/skills" swiftdata
  run_extract "$row" ../../.agents/skills/swiftdata ../../.pi/skills/swiftdata
  expect_case_silent "traversal-project-lookalike" 0

  row=$(row_dir traversal-home-agents)
  mkdir -p "$row/home/.claude/skills"
  make_standard_skill "$row/home/.agents/skills" swiftdata
  run_extract_no_cfg "$row" ../../.agents/skills/swiftdata
  expect_case_silent "traversal-home-agents" 0

  row=$(row_dir no-links)
  make_skill "$row/project/.claude/skills" swiftdata "$(skill_body 'This skill intentionally has no markdown links.')"
  run_extract "$row" swiftdata
  expect_case_silent "no-links" 0

  row=$(row_dir dot-segments)
  run_extract "$row" . ..
  expect_case_silent "dot-segments" 0

  row=$(row_dir unknown-skill)
  run_extract "$row" not-installed
  expect_case_silent "unknown-skill" 0

  row=$(row_dir no-skill-arguments)
  run_extract "$row"
  expect_case_silent "no-skill-arguments" 0

  row=$(row_dir only-separators)
  run_extract "$row" " , ,"
  expect_case_silent "only-separators" 0

  row=$(row_dir options)

  run bash "$SCRIPT" --help
  expect_case "help-long" 0 "Usage: bash extract-skill-follow-up-files.sh [--project-dir PATH]"

  run bash "$SCRIPT" -h
  expect_case "help-short" 0 "Usage: bash extract-skill-follow-up-files.sh"

  run bash "$SCRIPT" --project-dir
  expect_case "project-dir-without-value" 1 "--project-dir requires a value"

  run bash "$SCRIPT" --project-dir "$row/absent" swiftdata
  expect_status "missing-project-dir" 1

  assert_no_case_failures
}
