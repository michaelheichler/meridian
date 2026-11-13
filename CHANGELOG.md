# Changelog
This file records user-visible Meridian releases. Keep the newest entry first.

## [Unreleased]

### Meridian rename

- The product now uses the Meridian name, the `/meridian:` command prefix, and `/meridian:transit` as its driver command.
- Planning state now lives in `.meridian/`. Session startup moves `.lbwc-planning/` there when no destination exists and keeps both directories unchanged if they conflict.
- Runtime settings now use `MERIDIAN_*` names. Legacy `LBWC_*` values fill only current names that the environment does not already define.
- Role gates read legacy agent manifests during migration and deny actions when a manifest contains invalid data. Startup continues after a directory conflict.

## [1.0.5] - 2026-08-21

### A second way to get work done, and a fixed lookup

Some commands can now hand a job to a scripted workflow instead of only spawning agents one by one. Multi-step work can then run with less manual coordination.

- When the workflow path fits, build, debug, fix, init, map, qa, research, team, and vibe can each choose it. They run it once they pick it. The workflow path never falls back to the usual agent spawn. If the workflow cannot run, the command stops and reports the failure.
- Fixed a bug where the DevIQ advisor and saved debug sessions failed with a "no such file or directory" error instead of running.

## [1.0.4] - 2026-08-17

### Teams that follow Claude, and questions you can close

Starting a team now follows your Claude settings and the models this Claude offers.

- If Agent Teams is already on, you are not asked again.
- A project setting that turns teams off wins over a personal setting that turns them on.
- Starting a team skips a broken extra settings file. A file you pointed at on purpose still has to be valid.
- Close a choice dialog and work continues. The session is not stuck, and it is not pushed into a review you did not ask for.
- Teammates use the model names this Claude lists, including extra names from a router you installed.
- Starting a team refreshes that list so it accepts the short names Claude already uses.

## [1.0.3] - 2026-08-16

### TMUX agent panes

Run teammates as real Claude sessions in their own tmux panes. Your main session stays the orchestrator. It stays visible and in charge, and nothing takes it over.

- Each teammate runs in its own tmux pane as a real Claude session.
- Choose in-process agents or tmux panes. LBWC asks once, or you can save the choice in your LBWC settings.
- The choice freezes for the phase, so it does not flip mid-run.
- Cancel a spawn and it stops. Nothing silently falls back to in-process agents.
- Doctor and status show whether the pane runtime is healthy.
- Pane messaging lets the lead hand off work and collect results.
## [1.0.1] - 2026-08-11
### Fixed
- `AskUserQuestion` freeform handling no longer depends on a duplicated `Other` label. Any answer that is not a listed option now resolves as freeform in one step, matching the native contract.
- Re-derived the model-selector extraction in `claude-capabilities.sh` against the current Claude Code binary layout, restoring live model detection.
- Restored VBW-parity content that the initial port had summarized away (`report.md`, `research.md`, `config.md`, `map.md`, `debug.md`). Also quoted bracketed `argument-hint` frontmatter values that were failing strict plugin validation.
- Removed dead legacy `config/model-profiles.json`, `config/model-pricing.json`, and `config/reasoning-profiles.json`, and the one ShellCheck error plus five warnings across `scripts/`.
### Changed
- A clean install now includes command, script, reference, and test files that earlier 1.0.x checkouts lacked. The plugin's own commands and hooks can now resolve everything they reference.
## [1.0.0] - 2026-08-09
### Added
- Shell-issued worker contracts, protected execution boundaries, and main-session telemetry.
- A local RTK lifecycle manager with checksummed project-local installs and read-only Claude Code smoke checks.
- Release verification that requires synchronized version metadata and a changelog entry before publication.
- Claude Code marketplace catalog for `claude plugin marketplace add michaelheichler/meridian` and `claude plugin install lbwc@lbwc-marketplace`.
- Installation and update instructions for user, project, and local marketplace checks.
### Changed
- LBWC now treats generated agents as untrusted workers. The main session remains the only Git and release actor.
