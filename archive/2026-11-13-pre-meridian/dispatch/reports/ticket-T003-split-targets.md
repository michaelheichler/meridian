# T003 Split-group targets go stale after a later split

Commit 24e9a4d on the branch fixes it, and the five tmux files pass 32 of 32 under both shells with the safe fixture. Test rows follow from the T002c test writer. The T002 test writer found the problem on 3db16b6.

## Finding

A split group of `worker-a` and `worker-b` can store `session:0.1` as the `tmux_target` of both workers. The second split shifts the pane index of the first one. `kill-agent` for that target then reads two pane IDs and fails with `registered agent pane identity is invalid`.

- `scripts/lib/tmux-agent-orchestrator-split.sh:17` derives an index target from `display-message`.
- Lines 4-5 store it and never refresh the targets of earlier members.
- The reproduction lives in `/tmp/t002-single-tmux.tap` with the two-worker fixture.

## Plan

Make the stored target stable. Either address panes by pane ID everywhere a target selects one agent, or refresh every member's target from its pane ID after the group finishes splitting. The registry keeps both the pane ID and the human-readable target.

## Done when

- A two-worker group stores distinct targets that still point at the right panes after the group finishes.
- `kill-agent` works for each worker of a multi-worker group.
- The T002 test writer's two-worker kill row passes without its skip.
