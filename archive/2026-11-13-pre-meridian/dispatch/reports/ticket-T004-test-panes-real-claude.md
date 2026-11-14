# T004 Test tmux panes can start the real claude client

Commit 88042e6 on the branch (worker commit e061d54) fixes it. The attach-policy table, with its new probe row, passes in the main tree. A full tmux run under both shells still has to confirm the fix. The T002 test writer found the problem on 2026-11-03. The first tmux runs of the T003 coder also used the unsafe fixture.

## Finding

The tmux test proxy `tests/tmux_orchestrator_proxy.bash` forces a clean shell with the stub PATH only when a test exports `LBWC_TEST_FAST_CHILD_ENV` (lines 10-31). Every other `split-window` call starts the user's login shell, which replaces PATH. The orchestrator then sends `exec claude --agent <name>` into the pane, and `claude` resolves to `/Users/michael/.local/bin/claude` instead of the test stub. A probe row captured that path in `/tmp/t002-child-resolution.tap`.

## Exposure

- Any test run that reached a plain `split-window` launch could start an interactive `claude --agent` process in a private tmux pane. Teardown killed the pane afterwards.
- No test passes `-p`, `--print` or a prompt argument. Whether a launched client made model calls depends on the generated agent definition, which may carry an `initialPrompt`. This stays unconfirmed.
- Candidates include the new T002 table, the tests built on `tests/tmux_config_fixture.bash` such as `visible-final-agent`, and full-suite runs during this session.

## Plan

1. The proxy starts every test pane with `$LBWC_TEST_CHILD_SHELL --noprofile --norc` and `PATH=$LBWC_TEST_CHILD_PATH`, and fails closed when either variable is missing.
2. Every tmux fixture sets those variables, including `new-session` paths.
3. One row asserts that `command -v claude` inside a pane prints the stub path.
4. No tmux suite runs until this fix merges.

## Done when

The probe row passes under both shells, and a full tmux run shows no process from `~/.local/bin/claude` started by a test.
