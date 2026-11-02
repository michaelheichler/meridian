#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper

AGENT_PATTERN='.claude/agents/lbwc-*-*-*-*.md'

setup() {
  setup_temp_dir
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  await_git_ai
  teardown_temp_dir
}

fresh_repo() {
  local repo="$TEST_TEMP_DIR/$1"
  mkdir -p "$repo/.lbwc-planning"
  cd "$repo" || return 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  printf 'init\n' > init.txt
  git add init.txt
  git commit -q -m "chore: init"
}

repo_with_remote() {
  fresh_repo "$1" || return 1
  git init -q --bare "$TEST_TEMP_DIR/$1-remote.git"
  git remote add origin "$TEST_TEMP_DIR/$1-remote.git"
  git push -q -u origin HEAD 2>/dev/null
}

tracking_config() {
  printf '{"planning_tracking":"%s","auto_push":"%s"}\n' "$1" "$2" > .lbwc-planning/config.json
}

planning_git() {
  bash "$SCRIPTS_DIR/planning-git.sh" "$@"
}

ignore_state() {
  planning_git "$@" || return
  printf 'planning-ignored=%s\n' "$(git check-ignore -q .lbwc-planning/STATE.md && echo yes || echo no)"
  printf 'transient-ignored=%s\n' "$(git check-ignore -q .lbwc-planning/.execution-state.json && echo yes || echo no)"
  printf 'agent-ignored=%s\n' "$(git check-ignore -q .claude/agents/lbwc-dev-01-02-abc.md && echo yes || echo no)"
  printf 'agent-pattern-lines=%s\n' "$(grep -cFx "$AGENT_PATTERN" .gitignore)"
  printf 'planning-lines=%s\n' "$(grep -cx '\.lbwc-planning/' .gitignore)"
  printf 'kept-user-rule=%s\n' "$(grep -cx 'node_modules/' .gitignore)"
}

listing_after() {
  planning_git "$@" || return
  ls -A . .lbwc-planning
}

commit_state() {
  planning_git "$@" || return
  printf 'subject=%s\n' "$(git log -1 --format=%s)"
  printf 'committed-files=%s\n' "$(git show --name-only --format= HEAD | tr '\n' ',')"
  printf 'remote-head=%s\n' "$(git ls-remote origin "refs/heads/$(git branch --show-current)" 2>/dev/null | cut -f1)"
  printf 'local-head=%s\n' "$(git rev-parse HEAD)"
}

reject_invalid_commands() {
  fresh_repo usage

  run planning_git
  expect_case no-command 1 "Usage"

  run planning_git rebase-everything
  expect_case unknown-command 1 "rebase-everything"

  run planning_git commit-boundary
  expect_case boundary-without-action 1 "commit-boundary <action>"

  assert_no_case_failures
}

leave_non_repository_untouched() {
  mkdir -p "$TEST_TEMP_DIR/plain/.lbwc-planning"
  cd "$TEST_TEMP_DIR/plain"
  printf '{"planning_tracking":"commit","auto_push":"after_phase"}\n' > .lbwc-planning/config.json

  run listing_after ensure-generated-agent-ignore
  expect_case agent-ignore-outside-repo 0 ".lbwc-planning"
  expect_case_absent agent-ignore-outside-repo ".gitignore"

  run listing_after sync-ignore
  expect_case sync-outside-repo 0 "config.json"
  expect_case_absent sync-outside-repo ".gitignore"

  run planning_git commit-boundary "archive milestone x"
  expect_case_silent boundary-outside-repo 0

  run planning_git push-after-phase
  expect_case_silent push-outside-repo 0

  assert_no_case_failures
}

ignore_generated_agents_once() {
  fresh_repo no-gitignore
  run ignore_state ensure-generated-agent-ignore
  expect_case no-gitignore 0 "agent-ignored=yes"
  expect_case no-gitignore 0 "agent-pattern-lines=1"

  fresh_repo existing-gitignore
  printf 'node_modules/\n' > .gitignore
  run ignore_state ensure-generated-agent-ignore
  expect_case existing-gitignore 0 "agent-ignored=yes"
  expect_case existing-gitignore 0 "kept-user-rule=1"

  fresh_repo already-ignored
  printf '%s\n' "$AGENT_PATTERN" > .gitignore
  run ignore_state ensure-generated-agent-ignore
  expect_case already-ignored 0 "agent-pattern-lines=1"

  assert_no_case_failures
}

sync_tracking_mode_ignores() {
  fresh_repo ignore-mode-new
  tracking_config ignore never
  run ignore_state sync-ignore
  expect_case ignore-mode-new 0 "planning-ignored=yes"
  expect_case ignore-mode-new 0 "agent-ignored=yes"

  fresh_repo ignore-mode-existing
  tracking_config ignore never
  printf 'node_modules/\n' > .gitignore
  run ignore_state sync-ignore
  expect_case ignore-mode-existing 0 "planning-ignored=yes"
  expect_case ignore-mode-existing 0 "kept-user-rule=1"

  fresh_repo ignore-mode-repeat
  tracking_config ignore never
  printf '.lbwc-planning/\n' > .gitignore
  run ignore_state sync-ignore .lbwc-planning/config.json
  expect_case ignore-mode-repeat 0 "planning-lines=1"

  fresh_repo commit-mode
  tracking_config commit never
  printf 'node_modules/\n.lbwc-planning/\n' > .gitignore
  run ignore_state sync-ignore
  expect_case commit-mode 0 "planning-ignored=no"
  expect_case commit-mode 0 "transient-ignored=yes"
  expect_case commit-mode 0 "kept-user-rule=1"

  fresh_repo manual-default
  printf 'node_modules/\n' > .gitignore
  run ignore_state sync-ignore
  expect_case manual-default 0 "planning-ignored=no"
  expect_case manual-default 0 "transient-ignored=yes"

  assert_no_case_failures
}

commit_and_push_configured_boundaries() {
  fresh_repo commit-tracking
  tracking_config commit never
  printf '# State\n' > .lbwc-planning/STATE.md
  printf '# Claude\n' > CLAUDE.md
  printf '{}\n' > .lbwc-planning/.execution-state.json
  run commit_state commit-boundary "archive milestone 01-auth"
  expect_case commit-tracking 0 "subject=chore(lbwc): archive milestone 01-auth"
  expect_case commit-tracking 0 ".lbwc-planning/STATE.md,"
  expect_case commit-tracking 0 "CLAUDE.md,"
  expect_case_absent commit-tracking ".execution-state.json"

  fresh_repo nothing-staged
  tracking_config commit never
  planning_git commit-boundary "first boundary"
  run commit_state commit-boundary "second boundary"
  expect_case nothing-staged 0 "subject=chore(lbwc): first boundary"

  fresh_repo manual-tracking
  tracking_config manual never
  printf '# State\n' > .lbwc-planning/STATE.md
  run commit_state commit-boundary "archive milestone 01-auth"
  expect_case manual-tracking 0 "subject=chore: init"

  repo_with_remote push-always
  tracking_config commit always
  run commit_state commit-boundary "archive milestone 01-auth"
  expect_case push-always 0 "remote-head=$(git rev-parse HEAD)"
  expect_case push-always 0 "subject=chore(lbwc): archive milestone 01-auth"

  fresh_repo push-always-without-upstream
  tracking_config commit always
  run commit_state commit-boundary "archive milestone 01-auth"
  expect_case push-always-without-upstream 0 "subject=chore(lbwc): archive milestone 01-auth"

  assert_no_case_failures
}

@test "planning git applies repository and tracking policy across command scenarios" {
  run_scenario_cases reject_invalid_commands leave_non_repository_untouched \
    ignore_generated_agents_once sync_tracking_mode_ignores \
    commit_and_push_configured_boundaries push_after_phase_with_upstream
}

push_after_phase_with_upstream() {
  local pushed_head

  repo_with_remote after-phase
  tracking_config manual after_phase
  git commit -q --allow-empty -m "feat: phase work"
  pushed_head=$(git rev-parse HEAD)
  run commit_state push-after-phase
  expect_case after-phase 0 "remote-head=$pushed_head"

  repo_with_remote never-push
  tracking_config manual never
  git commit -q --allow-empty -m "feat: phase work"
  run commit_state push-after-phase .lbwc-planning/config.json
  expect_case_absent never-push "remote-head=$(git rev-parse HEAD)"
  expect_case never-push 0 "local-head=$(git rev-parse HEAD)"

  fresh_repo no-upstream
  tracking_config manual after_phase
  run planning_git push-after-phase
  expect_case_silent no-upstream 0

  assert_no_case_failures
}
