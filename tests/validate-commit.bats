#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

setup() {
  printf 'feat(core): add thing\n\nbody that matches no format\n' > "$BATS_TEST_TMPDIR/good.txt"
  printf 'not a conventional subject\n\nfeat(core): a body line that looks valid\n' > "$BATS_TEST_TMPDIR/bad.txt"
}

run_validate_row() {
  local input
  input=$(jq -n --arg command "$1" --arg cwd "$BATS_TEST_TMPDIR" '{tool_input: {command: $command}, cwd: $cwd}')
  run bash "$SCRIPTS_DIR/validate-commit.sh" <<< "$input"
}

allow_row() {
  run_validate_row "$2"
  expect_case_silent "$1" 0
}

flag_row() {
  local label="$1" subject="$3" context
  run_validate_row "$2"
  expect_case "$label" 0 "does not match format"
  context=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")
  [[ "$context" == *"Got: $subject" ]] \
    || record_case_failure "$label" "context did not end with subject=[$subject] context=$context"
}

@test "commits with a valid subject or no inspectable subject stay silent" {
  reset_case_failures

  allow_row valid-subject 'git commit -m "feat(core): add new feature"'
  for type in feat fix test refactor perf docs style chore; do
    allow_row "type-$type" "git commit -m \"$type(core): add thing\""
  done
  allow_row non-commit-command 'git status'
  allow_row heredoc-valid $'git commit -m "$(cat <<\'EOF\'\nfeat(test): valid heredoc commit\n\nCo-Authored-By: Test\nEOF\n)"'
  allow_row heredoc-after-blank-line $'git commit -m "$(cat <<\'EOF\'\n\nfeat(01-02): add thing\n\nCo-Authored-By: Test\nEOF\n)"'
  allow_row heredoc-after-preamble-line $'git commit -m "$(cat <<\'EOF\'\nSome preamble comment line\nfeat(01-02): add thing\nEOF\n)"'
  allow_row valid-subject-with-unformatted-body 'git commit -m "feat(core): add thing" -m "body that matches no format"'
  allow_row single-quoted-multi-line $'git commit -m \'feat(core): add thing\n\nbody that matches no format\''
  allow_row message-file-relative-to-cwd 'git commit -F good.txt'
  allow_row long-flag-equals 'git commit --message="feat(a): s"'
  allow_row long-flag-space 'git commit --message "feat(a): s"'
  allow_row hyphenated-author-before-valid-m 'git commit --author="a-m b" -m "feat(a): s"'
  allow_row subject-mentions-m-flag 'git commit -m "feat(a): handle -m flag"'
  allow_row amend-no-edit-without-message 'git commit --amend --no-edit'
  allow_row missing-message-file 'git commit --file=/missing'

  assert_no_case_failures
}

@test "commits with a malformed subject are flagged with the offending subject" {
  reset_case_failures

  flag_row plain-bad-message 'git commit -m "bad commit message"' 'bad commit message'
  flag_row unknown-type 'git commit -m "wip(core): add thing"' 'wip(core): add thing'
  flag_row heredoc-without-conventional-line $'git commit -m "$(cat <<\'EOF\'\nfixed a bug\nEOF\n)"' 'fixed a bug'
  flag_row bad-subject-then-valid-m 'git commit -m "bad subject" -m "feat(core): looks valid"' 'bad subject'
  flag_row message-file-bad-subject 'git commit -F bad.txt' 'not a conventional subject'
  flag_row long-flag-equals 'git commit --message="bad"' 'bad'
  flag_row long-flag-space 'git commit --message "bad s"' 'bad s'
  flag_row hyphenated-author-before-bad-m 'git commit --author="a-m b" -m "bad s"' 'bad s'
  flag_row bad-m-before-trailer-with-m 'git commit -m "bad s" --trailer "K: v -m w"' 'bad s'
  flag_row trailer-with-m-before-bad-m 'git commit --trailer "K: v -m w" -m "bad s"' 'bad s'
  flag_row combined-short-flags 'git commit -sm "bad s"' 'bad s'
  flag_row attached-unquoted-value 'git commit -m"bad"' 'bad'
  flag_row single-quoted-value "git commit -m 'bad s'" 'bad s'
  flag_row bad-m-after-fixup 'git commit --fixup=x -m "bad"' 'bad'

  assert_no_case_failures
}
