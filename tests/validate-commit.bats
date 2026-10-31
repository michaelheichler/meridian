#!/usr/bin/env bats

load test_helper

@test "passes valid conventional commit" {
  INPUT='{"tool_input":{"command":"git commit -m \"feat(core): add new feature\""}}'
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
}

@test "flags invalid commit format" {
  INPUT='{"tool_input":{"command":"git commit -m \"bad commit message\""}}'
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "does not match format"
}

@test "passes non-commit commands" {
  INPUT='{"tool_input":{"command":"git status"}}'
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validates heredoc-style commits" {
  INPUT=$(printf '{"tool_input":{"command":"git commit -m \\"$(cat <<'"'"'EOF'"'"'\\nfeat(test): valid heredoc commit\\n\\nCo-Authored-By: Test\\nEOF\\n)\\""}}'  )
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
}

@test "finds the conventional-commit line past a leading blank line in the heredoc" {
  INPUT=$(printf '{"tool_input":{"command":"git commit -m \\"$(cat <<'"'"'EOF'"'"'\\n\\nfeat(01-02): add thing\\n\\nCo-Authored-By: Test\\nEOF\\n)\\""}}'  )
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "finds the conventional-commit line past a non-blank preamble line in the heredoc" {
  INPUT=$(printf '{"tool_input":{"command":"git commit -m \\"$(cat <<'"'"'EOF'"'"'\\nSome preamble comment line\\nfeat(01-02): add thing\\nEOF\\n)\\""}}'  )
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "flags a heredoc body where no line matches conventional-commit format" {
  INPUT=$(printf '{"tool_input":{"command":"git commit -m \\"$(cat <<'"'"'EOF'"'"'\\nfixed a bug\\nEOF\\n)\\""}}'  )
  run bash -c "echo '$INPUT' | bash '$SCRIPTS_DIR/validate-commit.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "does not match format"
}

setup() {
  printf 'feat(core): add thing\n\nbody that matches no format\n' > "$BATS_TEST_TMPDIR/good.txt"
  printf 'not a conventional subject\n\nfeat(core): a body line that looks valid\n' > "$BATS_TEST_TMPDIR/bad.txt"
}

run_validate_in_test_dir() {
  local command="$1" input
  input=$(jq -n --arg command "$command" --arg cwd "$BATS_TEST_TMPDIR" '{tool_input: {command: $command}, cwd: $cwd}')
  run bash "$SCRIPTS_DIR/validate-commit.sh" <<< "$input"
  [ "$status" -eq 0 ]
}

assert_commit_passes() {
  run_validate_in_test_dir "$1"
  [ -z "$output" ]
}

assert_commit_flagged_on_subject() {
  run_validate_in_test_dir "$1"
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" == *"Got: $2" ]]
}

bats_test_function --description "a valid subject with a body that matches no format passes" -- assert_commit_passes 'git commit -m "feat(core): add thing" -m "body that matches no format"'
bats_test_function --description "a single-quoted multi-line message passes on its valid subject" -- assert_commit_passes $'git commit -m \'feat(core): add thing\n\nbody that matches no format\''
bats_test_function --description "a message file with a valid subject passes when named relative to the input cwd" -- assert_commit_passes 'git commit -F good.txt'
bats_test_function --description "an invalid subject is flagged even when a later -m looks valid" -- assert_commit_flagged_on_subject 'git commit -m "bad subject" -m "feat(core): looks valid"' 'bad subject'
bats_test_function --description "a message file with an invalid subject is flagged even when its body looks valid" -- assert_commit_flagged_on_subject 'git commit -F bad.txt' 'not a conventional subject'
