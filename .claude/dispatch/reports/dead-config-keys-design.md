# Designs for the nine unread configuration keys

The owner approved building all nine keys on 2026-11-01. Each key appears in `commands/config.md`, and the validator accepts it. Before this work, no script or command prompt read any of them. Every design keeps the documented type and default, so existing configurations keep their meaning.

## Display and runtime

| Key | Default | Behavior |
| --- | --- | --- |
| `visual_format` | `unicode` | `ascii` replaces box, bar, check, and warning glyphs with ASCII equivalents in the statusline, the status card, `help-output.sh`, and the research and verification emitters. One shared glyph table in `scripts/lib/` holds both sets. |
| `debug_logging` | `false` | `true` makes the hook dispatcher and the gate scripts append one line per decision to `.meridian/.debug.log` with the time, hook, tool, decision, and reason. The file rotates at 1 MB to `.debug.log.1`. The log never holds prompts, payloads, or secrets. |

## tmux runtime

| Key | Default | Behavior |
| --- | --- | --- |
| `tmux_execution.session_name_prefix` | `meridian` | `scripts/tmux-session-name.sh` reads the prefix instead of the hardcoded `meridian`. The validator already limits it to 1 to 32 ASCII characters. |
| `tmux_execution.attach_policy` | `orchestrator_only` | `orchestrator_only` keeps focus on the orchestrator pane after each split. `visible_grid` applies the configured layout to all panes and leaves the newest agent pane visible. |
| `tmux_execution.heartbeat_interval_seconds` | `30` | Agents send a bus heartbeat at this interval. The watchdog marks an agent stale after three missed intervals, unless a stricter explicit threshold applies. |

## Workflow

| Key | Default | Behavior |
| --- | --- | --- |
| `pipeline_research` | `false` | `true` makes `/meridian:transit` route a phase through the research step before planning when the phase has no research artifact. `false` keeps research optional. |
| `branch_per_milestone` | `false` | `true` makes the main session create and switch to `milestone/<slug>` when a milestone starts, and offer the merge back at milestone completion. The main session owns all Git actions. The branch step refuses to run on a dirty tree. |
| `plain_summary` | `true` | `true` adds a short "In plain words" section for the human at the top of each phase `SUMMARY.md`. `false` omits the section. |
| `qa_skip_agents` | `["docs"]` | Tasks owned only by the listed roles skip the QA agent. The main session still records a verification entry that names the skip and the reason. A task with mixed owners still gets QA. |

## Shared rules

1. Each key gets one reader, so docs, validator, and code cannot drift. A contract test compares the documented key list with the keys the code reads.
2. Every behavior gets accept and reject rows that fail on the code before the change.
3. All code runs on bash 3.2, and the statusline path adds no extra process per render.
