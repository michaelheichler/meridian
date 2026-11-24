#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

setup() {
  git init -q "$BATS_TEST_TMPDIR"
  cd "$BATS_TEST_TMPDIR" || return 1
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

@test "validate-commit stays silent for a valid or uninspectable subject and flags a malformed subject with the offending text" {
  reset_case_failures

  allow_row valid-subject 'git commit -m "feat(core): add new feature"'
  allow_row type-feat 'git commit -m "feat(core): add thing"'
  allow_row type-fix 'git commit -m "fix(core): add thing"'
  allow_row type-test 'git commit -m "test(core): add thing"'
  allow_row type-refactor 'git commit -m "refactor(core): add thing"'
  allow_row type-perf 'git commit -m "perf(core): add thing"'
  allow_row type-docs 'git commit -m "docs(core): add thing"'
  allow_row type-style 'git commit -m "style(core): add thing"'
  allow_row type-chore 'git commit -m "chore(core): add thing"'
  allow_row non-commit-command 'git status'
  allow_row heredoc-valid $'git commit -m "$(cat <<\'EOF\'\nfeat(test): valid heredoc commit\n\nCo-Authored-By: Test\nEOF\n)"'
  allow_row heredoc-after-blank-line $'git commit -m "$(cat <<\'EOF\'\n\nfeat(01-02): add thing\n\nCo-Authored-By: Test\nEOF\n)"'
  allow_row heredoc-after-preamble-line $'git commit -m "$(cat <<\'EOF\'\nSome preamble comment line\nfeat(01-02): add thing\nEOF\n)"'
  allow_row valid-subject-with-unformatted-body 'git commit -m "feat(core): add thing" -m "body that matches no format"'
  allow_row single-quoted-multi-line $'git commit -m \'feat(core): add thing\n\nbody that matches no format\''
  allow_row message-file-relative-to-cwd 'git commit -F good.txt'
  allow_row valid-long-flag-equals 'git commit --message="feat(a): s"'
  allow_row valid-long-flag-space 'git commit --message "feat(a): s"'
  allow_row hyphenated-author-before-valid-m 'git commit --author="a-m b" -m "feat(a): s"'
  allow_row subject-mentions-m-flag 'git commit -m "feat(a): handle -m flag"'
  allow_row amend-no-edit-without-message 'git commit --amend --no-edit'
  allow_row missing-message-file 'git commit --file=/missing'

  flag_row plain-bad-message 'git commit -m "bad commit message"' 'bad commit message'
  flag_row unknown-type 'git commit -m "wip(core): add thing"' 'wip(core): add thing'
  flag_row heredoc-without-conventional-line $'git commit -m "$(cat <<\'EOF\'\nfixed a bug\nEOF\n)"' 'fixed a bug'
  flag_row bad-subject-then-valid-m 'git commit -m "bad subject" -m "feat(core): looks valid"' 'bad subject'
  flag_row message-file-bad-subject 'git commit -F bad.txt' 'not a conventional subject'
  flag_row bad-long-flag-equals 'git commit --message="bad"' 'bad'
  flag_row bad-long-flag-space 'git commit --message "bad s"' 'bad s'
  flag_row hyphenated-author-before-bad-m 'git commit --author="a-m b" -m "bad s"' 'bad s'
  flag_row bad-m-before-trailer-with-m 'git commit -m "bad s" --trailer "K: v -m w"' 'bad s'
  flag_row trailer-with-m-before-bad-m 'git commit --trailer "K: v -m w" -m "bad s"' 'bad s'
  flag_row combined-short-flags 'git commit -sm "bad s"' 'bad s'
  flag_row attached-unquoted-value 'git commit -m"bad"' 'bad'
  flag_row single-quoted-value "git commit -m 'bad s'" 'bad s'
  flag_row bad-m-after-fixup 'git commit --fixup=x -m "bad"' 'bad'

  assert_no_case_failures
}

@test "validate-commit reads the message only from the git commit segment of a compound, wrapped, or quoted command" {
  reset_case_failures

  allow_row echo-mention 'echo git commit -m bad'
  allow_row quoted-function-arg $'python3 probe.py \'f() { shift; "$@"; }; f x git commit -m x\''
  allow_row runner-arg "python3 runner.py 'git commit -m bad'"
  allow_row sh-c-as-data $'printf %s "sh -c \'git commit -m bad\'"'
  allow_row bad-m-on-non-commit-segment 'echo -m bad && git commit -m "feat(a): s"'
  allow_row valid-subject-with-apostrophe $'git commit -m "fix(a): don\'t drop x"'

  flag_row env-wrapped 'env FOO=1 git commit -m x' 'x'
  flag_row git-C 'git -C /path commit -m x' 'x'
  flag_row git-c 'git -c k=v commit -m x' 'x'
  flag_row after-and 'git status && git commit -m x' 'x'
  flag_row after-semicolon 'true; git commit -m x' 'x'
  flag_row timeout-wrapped 'timeout 5 git commit -m x' 'x'

  assert_no_case_failures
}

@test "validate-commit finds the subject in quoted flag values, shell bodies, compound commands, substitutions, and continued lines" {
  reset_case_failures

  allow_row apostrophe-before-scope-close $'git commit -m "feat(user\'s): add x"'
  allow_row heredoc-after-valid-commit $'git commit -m "feat(a): x" && cat <<EOF\nrandom text\nEOF'

  flag_row long-message-equals-quoted 'git commit --message="bad msg"' 'bad msg'
  flag_row short-message-attached-quoted 'git commit -m"bad msg"' 'bad msg'
  flag_row xargs-wrapped 'echo x | xargs git commit -m bad' 'bad'
  flag_row absolute-git-path '/usr/bin/git commit -m bad' 'bad'
  flag_row brace-group '{ git commit -m bad; }' 'bad'
  flag_row if-then-body 'if true; then git commit -m bad; fi' 'bad'
  flag_row for-do-body 'for f in a; do git commit -m bad; done' 'bad'
  flag_row bash-c-body 'bash -c "git commit -m bad"' 'bad'
  flag_row sh-c-body "sh -c 'git commit -m bad'" 'bad'
  flag_row backtick-substitution 'echo `git commit -m bad`' 'bad'
  flag_row line-continuation $'git commit \\\n  -m bad' 'bad'

  assert_no_case_failures
}

@test "validate-commit stays silent and logs a parser failure when the commit parser crashes" {
  local fake_bin="$BATS_TEST_TMPDIR/fake-bin" input
  mkdir -p "$fake_bin" "$BATS_TEST_TMPDIR/.meridian"
  printf '#!/bin/sh\nprintf bad\nexit 2\n' > "$fake_bin/python3"
  chmod +x "$fake_bin/python3"
  printf '{"debug_logging": true}\n' > "$BATS_TEST_TMPDIR/.meridian/config.json"
  input=$(jq -n --arg cwd "$BATS_TEST_TMPDIR" '{tool_input: {command: "git commit -m bad"}, cwd: $cwd}')

  run env HOME="$BATS_TEST_TMPDIR" MERIDIAN_PLANNING_DIR="$BATS_TEST_TMPDIR/.meridian" PATH="$fake_bin:$PATH" \
    bash "$SCRIPTS_DIR/validate-commit.sh" <<< "$input"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run grep -c 'decision=error .*reason=commit_parser_failed' "$BATS_TEST_TMPDIR/.meridian/.debug.log"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}
