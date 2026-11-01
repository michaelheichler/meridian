#!/usr/bin/env bats

load test_helper
load guard_helper

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

run_guard() {
  local command="$1" agent_id="${2:-}" override="${3:-}"
  payload "tool_input.command=$command" "agent_id=$agent_id" \
    | LBWC_ALLOW_DESTRUCTIVE="$override" bash "$SCRIPTS_DIR/bash-guard.sh"
}

register_agent() {
  local id="$1" role="$2" state="$3"
  rm -f "$TEST_TEMP_DIR/.lbwc-planning/.agent-manifest.json"
  [ "$role" != "-" ] || return 0
  write_manifest "$TEST_TEMP_DIR/.lbwc-planning" "$(jq -cn --arg id "$id" --arg role "$role" --arg state "$state" --arg root "$TEST_TEMP_DIR" \
    '{agents:{($id):({role:$role,project_root:$root,write_allowances:[]} + (if $state == "-" then {} else {state:$state} end))}}')"
}

apply_setup() {
  case "$1" in
    local-list) printf '%s\n' 'frobnicate[[:space:]]+--all' > "$TEST_TEMP_DIR/.lbwc-planning/destructive-commands.local.txt" ;;
  esac
}

override_for() {
  [ "$1" != "override" ] || printf '1'
}

@test "bash-guard allows ordinary commands without side effects" {
  local before after
  while IFS='|' read -r label id role state setup command; do
    [ -n "$label" ] || continue
    register_agent "$id" "$role" "$state"
    apply_setup "$setup"
    before=$(tree_digest "$TEST_TEMP_DIR")
    run run_guard "$command" "$id" "$(override_for "$setup")"
    after=$(tree_digest "$TEST_TEMP_DIR")
    expect_status "$label" 0
    expect_output_empty "$label"
    expect_same_digest "$label" "$before" "$after"
  done <<'CASES'
innocuous-main-session|-|-|-|-|ls -la
git-push-without-force|-|-|-|-|git push origin main
destructive-command-with-override|-|-|-|override|rm -rf /var/lib/mysql
local-destructive-list-miss|-|-|-|local-list|frobnicate --one
empty-command|-|-|-|-|
unlisted-agent-without-manifest|dev-9|-|-|-|echo hi > out.txt
scout-read-only-git|scout-1|scout|-|-|git status
scout-quoted-redirect-character|scout-1|scout|-|-|grep ">" file.txt
qa-read-only-listing|qa-1|qa|-|-|ls -la
python-engineer-redirect|dev-1|python-engineer|-|-|echo hi > out.txt
registered-worker-template-bash|lbwc-python-engineer-a|python-engineer|registered|-|printf x
running-worker-ordinary-bash|lbwc-docs-a|docs|running|-|printf '%s\n' ready
forged-identity-ordinary-command|lbwc-forged-agent|-|-|-|printf x
CASES
}

@test "bash-guard allows an empty stdin payload" {
  run bash -c "printf '' | bash '$SCRIPTS_DIR/bash-guard.sh'"

  expect_status empty-stdin 0
  expect_output_empty empty-stdin
}

@test "bash-guard blocks commands on the destructive list unless overridden" {
  while IFS='|' read -r label setup reason command; do
    [ -n "$label" ] || continue
    apply_setup "$setup"
    run run_guard "$command" "" "$(override_for "$setup")"
    expect_status "$label" 2
    expect_output_has "$label" "$reason"
    expect_output_has "$label" "Hint: Use LBWC_ALLOW_DESTRUCTIVE=1 to override."
  done <<'CASES'
recursive-delete|-|destructive command detected|rm -rf /var/lib/mysql
force-push|-|destructive command detected|git push --force origin main
local-list-entry|local-list|destructive command detected (frobnicate --all|frobnicate --all
CASES
}

@test "bash-guard keeps scout and qa read-only even with the destructive override" {
  while IFS='|' read -r label id role setup reason command; do
    [ -n "$label" ] || continue
    register_agent "$id" "$role" "-"
    run run_guard "$command" "$id" "$(override_for "$setup")"
    expect_status "$label" 2
    expect_output_has "$label" "$reason"
  done <<'CASES'
scout-write-redirect|scout-1|scout|-|write redirection, substitution, or eval|echo hi > out.txt
scout-append-redirect|scout-1|scout|-|write redirection, substitution, or eval|echo hi >> out.txt
scout-command-substitution|scout-1|scout|-|write redirection, substitution, or eval|echo $(whoami)
scout-backtick-substitution|scout-1|scout|-|write redirection, substitution, or eval|echo `whoami`
scout-eval|scout-1|scout|-|write redirection, substitution, or eval|eval ls
scout-nested-shell|scout-1|scout|-|nested shell execution|bash -c ls
scout-filesystem-mutation-in-pipe|scout-1|scout|-|filesystem mutation command|echo hi | tee out.txt
qa-filesystem-mutation|qa-1|qa|-|filesystem mutation command|mkdir newdir
scout-redirect-with-destructive-override|scout-1|scout|override|write redirection, substitution, or eval|echo hi > out.txt
CASES
}

@test "bash-guard confines generated agents to the main-session command policy" {
  while IFS='|' read -r label id role state setup reason command; do
    [ -n "$label" ] || continue
    register_agent "$id" "$role" "$state"
    run run_guard "$command" "$id" "$(override_for "$setup")"
    expect_status "$label" 2
    expect_output_has "$label" "$reason"
  done <<'CASES'
protected-policy-read|lbwc-docs-a|docs|running|-|protected control path|cat config/subagent-critical-execution.txt
protected-policy-redirect|lbwc-docs-a|docs|running|-|protected control path|printf x > config/subagent-critical-execution.txt
protected-python-policy|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('config/subagent-critical-execution.txt', 'w')"
protected-python-planning-config|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('.lbwc-planning/config.json', 'w')"
protected-python-guard-script|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('scripts/bash-guard.sh', 'w')"
protected-python-contract-script|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('scripts/task-contract.sh', 'w')"
protected-python-lifecycle-script|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('scripts/agent-lifecycle.sh', 'w')"
protected-python-manifest|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('.lbwc-planning/.agent-manifest.json', 'w')"
protected-python-contract-store|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('.lbwc-planning/.contracts/tasks/forged.json', 'w')"
protected-python-agent-definition|lbwc-docs-a|docs|running|-|protected control path|python3 -c "open('.claude/agents/forged.md', 'w')"
protected-python-split-path|lbwc-docs-a|docs|running|-|protected control path|python3 -c "from pathlib import Path; Path('config') / 'subagent-critical-execution.txt'"
shell-source-keyword|lbwc-docs-a|docs|running|-|shell execution route|source payload.sh
shell-source-dot|lbwc-docs-a|docs|running|-|shell execution route|. payload.sh
shell-stdin-redirect|lbwc-docs-a|docs|running|-|shell execution route|echo sh < payload.sh
shell-code-flag-after-word|lbwc-docs-a|docs|running|-|shell execution route|echo bash -c payload
shell-interpreter-script|lbwc-docs-a|docs|running|-|shell execution route|bash scripts/wrapper-that-runs-git.sh
shell-interpreter-sh-script|lbwc-docs-a|docs|running|-|shell execution route|sh scripts/wrapper-that-runs-git.sh
shell-interpreter-via-rtk-proxy|lbwc-docs-a|docs|running|-|shell execution route|rtk proxy bash scripts/wrapper-that-runs-git.sh
shell-interpreter-via-env|lbwc-docs-a|docs|running|-|shell execution route|env CI=1 zsh -c 'git status'
shell-interpreter-via-command|lbwc-docs-a|docs|running|-|shell execution route|command bash payload.sh
shell-interpreter-via-exec|lbwc-docs-a|docs|running|-|shell execution route|exec sh payload.sh
shell-ifs-expansion-braced|lbwc-docs-a|docs|running|-|shell execution route|bash${IFS}-c${IFS}'printf ready'
shell-ifs-expansion-bare|lbwc-docs-a|docs|running|-|shell execution route|bash $IFS-c 'printf ready'
shell-heredoc-string|lbwc-docs-a|docs|running|-|shell execution route|bash <<< 'git status'
shell-pipe-into-interpreter|lbwc-docs-a|docs|running|-|shell execution route|printf x | sh
git-plain|lbwc-docs-a|docs|running|-|Git is reserved for the main session|git status
git-backslash-escaped|lbwc-docs-a|docs|running|-|Git is reserved for the main session|\git status
git-quoted|lbwc-docs-a|docs|running|-|Git is reserved for the main session|"git" status
git-split-by-backslash|lbwc-docs-a|docs|running|-|Git is reserved for the main session|g\it status
git-via-rtk|lbwc-docs-a|docs|running|-|Git is reserved for the main session|rtk git status
git-via-rtk-proxy|lbwc-docs-a|docs|running|-|Git is reserved for the main session|rtk proxy git status
git-via-rtk-proxy-quoted|lbwc-docs-a|docs|running|-|Git is reserved for the main session|rtk proxy "git" status
git-via-command|lbwc-docs-a|docs|running|-|Git is reserved for the main session|command git status
git-via-env|lbwc-docs-a|docs|running|-|Git is reserved for the main session|env GIT_DIR=. git status
git-by-absolute-path|lbwc-docs-a|docs|running|-|Git is reserved for the main session|/usr/bin/git status
git-with-destructive-override|lbwc-docs-a|docs|running|override|Git is reserved for the main session|git status
git-from-forged-identity|lbwc-forged-agent|-|-|-|Git is reserved for the main session|git status
git-from-spent-worker|lbwc-docs-a|docs|used|-|Git is reserved for the main session|git status
critical-nested-runtime|lbwc-docs-a|docs|running|-|critical execution command|claude --version
critical-package-mutation|lbwc-docs-a|docs|running|-|critical execution command|npm install example
critical-remote-transfer|lbwc-docs-a|docs|running|-|critical execution command|curl https://example.com
critical-remote-transfer-escaped|lbwc-docs-a|docs|running|-|critical execution command|c\url https://example.com
critical-privilege|lbwc-docs-a|docs|running|-|critical execution command|sudo true
critical-termination|lbwc-docs-a|docs|running|-|critical execution command|kill 123
CASES
}

@test "bash-guard blocks generated agents when the critical execution policy file is missing" {
  local isolated_plugin="$TEST_TEMP_DIR/isolated-plugin"
  mkdir -p "$isolated_plugin/scripts"
  cp "$SCRIPTS_DIR/bash-guard.sh" "$isolated_plugin/scripts/bash-guard.sh"
  register_agent lbwc-docs-a docs running

  run bash -c 'jq -cn "{tool_input:{command:\"printf x\"},agent_id:\"lbwc-docs-a\"}" | bash "$1"' _ "$isolated_plugin/scripts/bash-guard.sh"

  expect_status policy-file-missing 2
  expect_output_has policy-file-missing "critical execution policy is unavailable"
}

@test "bash-guard fails closed when jq is missing" {
  local no_jq_path="$TEST_TEMP_DIR/no-jq-bin"
  mkdir -p "$no_jq_path"
  ln -s "$(command -v bash)" "$no_jq_path/bash"

  run env PATH="$no_jq_path" bash -c "printf '%s' '{}' | bash '$SCRIPTS_DIR/bash-guard.sh'"

  expect_status jq-missing 2
  expect_output_has jq-missing "jq not available"
}

@test "generated implementation roles deny Bash by default" {
  run jq -e '
    . as $defaults
    | ["debugger", "coding-dijkstra", "python-engineer", "web-engineer", "qa-author", "test-dev"]
    | all(.[]; ($defaults[.].disallowedTools | split(", ") | index("Bash")) != null)
  ' "$PROJECT_ROOT/templates/agent-roles/defaults.json"
  [ "$status" -eq 0 ]
}
