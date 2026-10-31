# Code Report

**Repo:** michaelheichler/lbwc
**Commit:** 534b22a86a460bf06858ceb42f351e904bc16984
**Generated:** 2026-10-31T11:54:13Z
**Branch:** main (plan branch `refactor/meridian-2.0`)

## Tech Stack

- **Languages:** Bash (about 40k lines in `scripts/` and `scripts/lib/`), Python 3 (hooks in `hooks/`), Markdown (commands, templates, references)
- **Runtime:** Claude Code plugin, verified against Claude Code 2.1.231
- **Tools:** jq (about 1470 calls), tmux (optional pane runtime), git
- **Test framework:** bats-core 1.14.0 (106 files, 1589 tests), Python unittest (`hooks/test_*.py`)
- **CI/CD:** GitHub Actions, `.github/workflows/routing-platform-locks.yml` and `skills-discovery.yml`

## Architecture Overview

`commands/*.md` are slash commands (all `disable-model-invocation: true`). They call bash helpers in `scripts/` through `${CLAUDE_PLUGIN_ROOT}`. `hooks/hooks.json` wires SessionStart, PreCompact, PreToolUse, PostToolUse, Stop and team events to `scripts/hook-wrapper.sh` and to the Python guards. Project state lives in `.lbwc-planning/` (PROJECT, STATE, ROADMAP, CONTEXT, RESUME, per-phase PLAN/SUMMARY/VERIFICATION/UAT). `scripts/agent-generator.sh` builds role agents from `templates/agent-roles/*.md.tpl`.

## Directory Structure

```
commands/        33 slash commands, 430 KB
scripts/         bash helpers, hooks targets, statusline
scripts/lib/     shared bash libraries
hooks/           Python guards and hooks.json
templates/       agent role and workflow templates
references/      protocol docs and the DevIQ corpus (1.5 MB)
skills-bundle/   bundled reference skills (3 MB), forced Read per role
tests/           bats suites and fixtures
tasks/           previous plan and todo, all DONE
```

## Key Patterns Observed

- **Code style:** `set -euo pipefail` in most large scripts. 63 files lack `pipefail`. shellcheck finds no errors, 18 warnings, 203 notes.
- **Error handling:** guards deny by exit code. `scripts/hook-wrapper.sh:31` maps every non-zero exit to `exit 2`, so a crash blocks the tool.
- **State management:** markdown and JSON files under `.lbwc-planning/`, with lock helpers in `scripts/lib/manifest-lock.sh`.
- **Feedback:** `scripts/session-start.sh` injects one status line. `scripts/lbwc-statusline.sh` draws the statusline.

## Dependencies of Note

- jq on every hook path. `file-guard.sh` forks jq 32 times per call.
- bash 4.3+ features in `agent-generator.sh`, `render-agent-template.sh`, `render-workflow-template.sh`, `workflow-generator.sh`, `tmux-spawn-group.sh`, `verification-freshness.sh`, with no `BASH_VERSINFO` check. macOS `/bin/bash` is 3.2.

## Test Coverage Assessment

- **Result on 2026-10-31:** 1526 ok, 63 not ok, serial `bats tests/`. The process hangs after the last test. `bats -j` needs GNU parallel, which is missing.
- **Failing clusters:** context cache and context index (233-262), phase-detect `qa_status` (766-805), team prepare (1257-1274), tmux watchdog (1300-1304), worktree cleanup (1497, 1511), singles 109, 137, 403, 667, 717, 857, 1187, 1356.
- **Leak:** one test created a self-link `lbwc` in the repo root.
- **Python:** 14 unittest tests, 2 errors, because `hooks/test_scope_guard.py` is a production hook with a `test_` prefix.
- **Coverage tool:** none measured yet.
- **README:** the badge claims 1189 passing.

## Risks and Technical Debt

1. `scripts/compaction-instructions.sh:91-105` never resets `.compaction-count`. After 10 compactions in a project, every compaction tells the agent to stop all work.
2. Stale "helper not installed" stop-text in `references/vibe-input-parsing.md:370,374,408`, `vibe-mode-milestone-uat-recovery.md:163`, `vibe-mode-insert-phase.md:48`, `vibe-mode-bootstrap.md:107`, `vibe-mode-execute.md:95`, `vibe-mode-archive.md:93`, `execute-uat.md:5,42,57,169,172,181,184`, `verification-protocol.md:5`.
3. `hooks/user_question_guard.py:41-47,734` denies read-only commands that only name a protected file.
4. `hooks/context_usage.py:59` estimates context as transcript bytes / 4 and never resets after compaction.
5. `/lbwc:pause` writes nothing without notes. Resume reads every PLAN and SUMMARY with no budget.
6. CHANGELOG 1.0.5 promises a workflow fallback that `commands/vibe.md:205,277` forbids.
7. The docs describe features that nobody built. Per-plan worktrees and a team marker appear in `references/execute-protocol.md:41,134`, and conditional refusal appears in `references/handoff-schemas.md:360`.
8. Seven interactive smoke rows are PENDING (`SMOKE-TESTS.md:43-49`), and the workflow backend has no smoke rows.

There is no earlier code report to compare against.
