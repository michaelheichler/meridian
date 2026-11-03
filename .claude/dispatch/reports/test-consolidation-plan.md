# MERIDIAN Test Suite Consolidation Plan

Analysis only. This step changed no test or production file. Repo path is `/Users/michael/Development/projects/meridian`.

## Method

- Test counts come from `grep -c '^@test' tests/*.bats`. Total 1589 across 106 files.
- Production mapping comes from script references in each file, sampled test bodies, and the source tree.
- Classification read every test name and sampled the bodies of the 40 largest files. Counts below are the design baseline, not a line-by-line audit of all 1589 bodies.
- Raw run evidence is `/tmp/meridian-bats.txt`, 1589 tests, 1526 ok, 63 not ok.
- The deterministic re-run used `env -u CDPATH bats tests/`. It completed all 1589 tests with 22 not ok and the process exited normally.

## 1. Inventory

Sorted by test count. K, M, B are keep, merge, delete. Target is the planned `@test` count for that file.

| File | Tests | Production under test | K | M | B | Target |
|---|---:|---|---:|---:|---:|---:|
| tests/phase-detect.bats | 151 | phase-detect.sh + lib/phase-detect-*.sh | 60 | 91 | 0 | 25 |
| tests/compile-verify-context.bats | 75 | compile-verify-context.sh, qa-result-gate.sh | 30 | 45 | 0 | 15 |
| tests/debug-session-state.bats | 54 | debug-session-state.sh, write-debug-session.sh | 24 | 30 | 0 | 12 |
| tests/agent-generator.bats | 41 | agent-generator.sh, task-contract.sh | 28 | 13 | 0 | 12 |
| tests/team-command.bats | 41 | team-command-transaction.sh, tmux-spawn-group.sh | 27 | 4 | 10 | 12 |
| tests/worktree-boundary.bats | 39 | session-stop.sh, doctor-cleanup.sh, compaction/post-compact | 20 | 19 | 0 | 8 |
| tests/qa-file-guard.bats | 34 | file-guard.sh | 20 | 14 | 0 | 8 |
| tests/qa-workflow-spawn-guard.bats | 33 | workflow-spawn-guard.sh, command-contract.sh | 14 | 19 | 0 | 5 |
| tests/task-contract.bats | 31 | task-contract.sh, task-admission/completion-guard | 18 | 13 | 0 | 10 |
| tests/claude-capabilities.bats | 30 | claude-capabilities.sh, meridian-config.sh | 20 | 10 | 0 | 8 |
| tests/research-session-state.bats | 30 | research-session-state.sh | 14 | 16 | 0 | 8 |
| tests/context-cache.bats | 27 | cache-context.sh, compile-context.sh | 8 | 19 | 0 | 4 |
| tests/meridian-routing.bats | 26 | meridian-routing.sh, lib/meridian-settings.sh | 18 | 8 | 0 | 8 |
| tests/tmux-bus.bats | 26 | tmux-bus.sh, lib/tmux-runtime.sh | 18 | 8 | 0 | 8 |
| tests/todo-lifecycle.bats | 26 | todo-lifecycle.sh, todo-details.sh | 16 | 10 | 0 | 8 |
| tests/qa-bash-guard.bats | 25 | bash-guard.sh | 16 | 9 | 0 | 6 |
| tests/resolve-agent-settings.bats | 25 | resolve-agent-settings.sh, render-agent-template.sh | 8 | 17 | 0 | 4 |
| tests/tmux-orchestrator.bats | 25 | tmux-agent-orchestrator.sh | 15 | 10 | 0 | 7 |
| tests/worktree.bats | 25 | worktree-create/merge/cleanup/status.sh | 12 | 13 | 0 | 5 |
| tests/meridian-conventions.bats | 24 | meridian-conventions.sh | 17 | 7 | 0 | 8 |
| tests/meridian-model.bats | 23 | meridian-model | 16 | 7 | 0 | 7 |
| tests/render-workflow-template.bats | 23 | render-workflow-template.sh, templates/workflows | 16 | 5 | 2 | 7 |
| tests/todo-details.bats | 23 | todo-details.sh | 13 | 10 | 0 | 6 |
| tests/write-verification.bats | 22 | write-verification.sh | 10 | 12 | 0 | 5 |
| tests/meridian-config.bats | 21 | meridian-config.sh, lib/meridian-settings.sh | 11 | 10 | 0 | 5 |
| tests/meridian-skills.bats | 21 | meridian-skills.sh, detect-stack.sh | 15 | 6 | 0 | 6 |
| tests/remediation-round.bats | 21 | remediation-round.sh, qa-remediation-state.sh | 13 | 8 | 0 | 6 |
| tests/write-debug-session.bats | 21 | write-debug-session.sh | 12 | 9 | 0 | 6 |
| tests/runtime-snapshot.bats | 20 | runtime-snapshot.sh | 15 | 5 | 0 | 6 |
| tests/plan-import.bats | 19 | plan-import.sh, adapters | 14 | 5 | 0 | 6 |
| tests/command-contract.bats | 18 | command-contract.sh | 18 | 0 | 0 | 8 |
| tests/compile-research-context.bats | 18 | compile-research-context.sh | 10 | 8 | 0 | 5 |
| tests/indexer-sync.bats | 18 | indexer-sync.sh, probe-map-tools.sh | 11 | 7 | 0 | 5 |
| tests/qa-result-gate.bats | 18 | qa-result-gate.sh | 11 | 7 | 0 | 5 |
| tests/extract-skill-follow-up-files.bats | 17 | extract-skill-follow-up-files.sh | 12 | 5 | 0 | 5 |
| tests/meridian-execution-config.bats | 17 | meridian-config.sh, migrate-config.sh | 10 | 7 | 0 | 5 |
| tests/meridian-routing-lock.bats | 17 | meridian-routing.sh lock backend | 12 | 5 | 0 | 5 |
| tests/debug-start-selected-todo.bats | 15 | debug-start-selected-todo.sh, todo-lifecycle.sh | 10 | 5 | 0 | 5 |
| tests/qa-gate.bats | 15 | qa-gate.sh, lib/qa-gate-decision.sh | 10 | 5 | 0 | 5 |
| tests/rtk-manager.bats | 14 | rtk-manager.sh | 12 | 2 | 0 | 6 |
| tests/session-start.bats | 13 | session-start.sh, agent-lifecycle.sh | 10 | 3 | 0 | 5 |
| tests/agent-lifecycle.bats | 12 | agent-lifecycle.sh, lib/tmux-runtime.sh | 9 | 3 | 0 | 5 |
| tests/build-command.bats | 12 | commands/build.md (doc prose) | 1 | 0 | 11 | 0 |
| tests/context-usage.bats | 12 | lib/resolve-caveman-level.sh (hook) | 6 | 6 | 0 | 3 |
| tests/map-tiers.bats | 12 | lib/map-tiers.sh | 5 | 7 | 0 | 2 |
| tests/qa-agent-spawn-guard.bats | 12 | agent-spawn-guard.sh | 9 | 3 | 0 | 4 |
| tests/statusline.bats | 12 | meridian-statusline.sh, statusline-install.sh | 9 | 3 | 0 | 5 |
| tests/delta-context.bats | 11 | delta-files.sh, compile-context.sh | 7 | 4 | 0 | 4 |
| tests/phase-detect-output-contract.bats | 11 | phase-detect.sh (fixtures) | 11 | 0 | 0 | 0 |
| tests/team-context-index.bats | 11 | team-context-index.sh | 8 | 3 | 0 | 4 |
| tests/workflow-manifest.bats | 11 | lib/workflow-manifest.sh | 9 | 2 | 0 | 5 |
| tests/deviq-lookup.bats | 10 | deviq-lookup.sh | 10 | 0 | 0 | 4 |
| tests/security-filter.bats | 10 | security-filter.sh | 10 | 0 | 0 | 2 |
| tests/doctor.bats | 9 | doctor-cleanup.sh, tmux-doctor.sh | 8 | 1 | 0 | 4 |
| tests/render-workflow-template-gate-loop.bats | 9 | render-workflow-template.sh + gate loop | 9 | 0 | 0 | 4 |
| tests/transit-command.bats | 9 | commands/transit.md (doc prose) | 0 | 0 | 9 | 0 |
| tests/plan-task-count.bats | 8 | plan-task-count.sh | 5 | 3 | 0 | 3 |
| tests/session-telemetry.bats | 8 | lib/session-telemetry.py | 8 | 0 | 0 | 4 |
| tests/teach-command.bats | 8 | commands/teach.md (doc prose) | 0 | 0 | 8 | 0 |
| tests/team-run-state.bats | 8 | team-run-state.sh, cleanup-temporary-agent-runfiles.sh | 6 | 2 | 0 | 3 |
| tests/host-agent-enum.bats | 7 | claude-capabilities.sh, meridian-routing.sh | 5 | 2 | 0 | 3 |
| tests/init-command.bats | 7 | commands/init.md (doc prose) | 1 | 0 | 6 | 1 |
| tests/map-command.bats | 7 | commands/map.md (doc prose) | 1 | 0 | 6 | 1 |
| tests/probe-map-tools.bats | 7 | probe-map-tools.sh | 4 | 3 | 0 | 2 |
| tests/research-command.bats | 7 | commands/research.md (doc prose) | 1 | 0 | 6 | 1 |
| tests/tmux-bus-watchdog.bats | 7 | tmux-bus-watchdog.sh | 7 | 0 | 0 | 4 |
| tests/tmux-spawn-group.bats | 7 | tmux-spawn-group.sh, tmux-bus.sh | 7 | 0 | 0 | 4 |
| tests/validate-commit.bats | 7 | validate-commit.sh | 7 | 0 | 0 | 2 |
| tests/version-release.bats | 7 | version-bump.sh, release-verify.sh | 7 | 0 | 0 | 3 |
| tests/zero-trust-contract.bats | 7 | references/templates markdown prose | 0 | 0 | 7 | 0 |
| tests/bootstrap-archive-helpers.bats | 6 | bootstrap-project.sh, archive-uat-guard.sh | 6 | 0 | 0 | 3 |
| tests/check-markdown-format.bats | 6 | check-markdown-format.sh | 6 | 0 | 0 | 2 |
| tests/context-index.bats | 6 | compile-context.sh index writer | 4 | 2 | 0 | 0 |
| tests/debug-start-manual.bats | 6 | debug-start-manual.sh | 5 | 1 | 0 | 3 |
| tests/list-todos.bats | 6 | list-todos.sh | 5 | 1 | 0 | 2 |
| tests/uat-remediation-helpers.bats | 6 | uat-remediation-state.sh, create-remediation-phase.sh | 6 | 0 | 0 | 3 |
| tests/workflow-spawn-protocol.bats | 6 | references/workflow-spawn-protocol.md | 0 | 0 | 6 | 0 |
| tests/control-root.bats | 5 | lib/meridian-control-root.sh | 5 | 0 | 0 | 2 |
| tests/debug-command.bats | 5 | commands/debug.md (doc prose) | 0 | 0 | 5 | 0 |
| tests/deviq-gate.bats | 5 | deviq-build-gate.sh | 5 | 0 | 0 | 2 |
| tests/deviq-nudge.bats | 5 | deviq-nudge.sh, deviq-lookup.sh | 5 | 0 | 0 | 2 |
| tests/import-command.bats | 5 | commands/import.md (doc prose) | 0 | 0 | 5 | 0 |
| tests/model-config-commands.bats | 5 | commands/models.md, commands/config.md (doc prose) | 0 | 0 | 5 | 0 |
| tests/qa-command.bats | 5 | commands/qa.md (doc prose) | 0 | 0 | 5 | 0 |
| tests/task-hooks.bats | 5 | task-admission-guard.sh, task-completion-guard.sh | 5 | 0 | 0 | 3 |
| tests/verify-state-consistency.bats | 5 | verify-state-consistency.sh | 5 | 0 | 0 | 2 |
| tests/clean-stale-teams.bats | 4 | clean-stale-teams.sh | 4 | 0 | 0 | 2 |
| tests/compile-context-skills.bats | 4 | compile-context.sh (removed skill emission) | 0 | 0 | 4 | 0 |
| tests/fix-command.bats | 4 | commands/fix.md (doc prose) | 0 | 0 | 4 | 0 |
| tests/map-staleness.bats | 4 | map-staleness.sh | 4 | 0 | 0 | 2 |
| tests/plugin-root.bats | 4 | resolve-plugin-root.sh, ensure-plugin-root-link.sh | 4 | 0 | 0 | 2 |
| tests/user-question-cancel.bats | 4 | hooks/user_question_guard.py | 4 | 0 | 0 | 2 |
| tests/deviq-digest-append.bats | 3 | deviq-digest-append.sh | 3 | 0 | 0 | 2 |
| tests/frontmatter-array-parser.bats | 3 | summary-utils.sh, verification-freshness.sh | 3 | 0 | 0 | 2 |
| tests/hook-wrapper.bats | 3 | hook-wrapper.sh | 3 | 0 | 0 | 2 |
| tests/infer-project-context.bats | 3 | infer-project-context.sh | 3 | 0 | 0 | 2 |
| tests/track-known-issues.bats | 3 | track-known-issues.sh | 3 | 0 | 0 | 2 |
| tests/transit-import-routing.bats | 3 | commands/transit.md, references/transit-input-parsing.md | 0 | 0 | 3 | 0 |
| tests/agent-routing-evidence.bats | 2 | agent-routing-evidence.sh | 2 | 0 | 0 | 1 |
| tests/compile-context.bats | 2 | compile-context.sh | 2 | 0 | 0 | 1 |
| tests/init-import-routing.bats | 2 | commands/init.md (doc prose) | 0 | 0 | 2 | 0 |
| tests/telemetry-report.bats | 2 | telemetry-report.sh | 2 | 0 | 0 | 1 |
| tests/tmux-preflight.bats | 2 | tmux-preflight.sh | 2 | 0 | 0 | 1 |
| tests/execution-backend-command.bats | 1 | commands/transit, build, and team markdown (doc prose) | 0 | 0 | 1 | 0 |
| tests/help-output.bats | 1 | help-output.sh | 1 | 0 | 0 | 1 |
| tests/marketplace.bats | 1 | .claude-plugin/marketplace.json (config) | 1 | 0 | 0 | 1 |
| **Total** | **1589** | | **932** | **552** | **105** | **425** |

## 2. Classification

### (a) Behavior worth keeping, 932 tests

These assert an observable production contract, meaning exit status plus output or state on disk.

- `tests/phase-detect.bats:89` UAT issue routing produces `next_phase_state=needs_uat_remediation`.
- `tests/qa-file-guard.bats:48` scout role cannot write product source.
- `tests/tmux-bus.bats:146` a registered principal needs its own capability and replies reach main.
- `tests/plan-import.bats:132` promotion rollback restores every destination.

### (b) Duplicate or near-duplicate, 552 tests

Same production branch, different literal. These become table rows, not separate tests.

- `tests/phase-detect.bats:2069`, `:2199`, `:2226` all drive the same PASS assessment path with the verification artifact in a different location.
- `tests/context-cache.bats:400`, `:460`, `:483` all call the same fingerprint helper with a different input file.
- `tests/resolve-agent-settings.bats:137-210` nine `max_turns` cases for one resolver.
- `tests/compile-verify-context.bats:370-567` remediation-only cases share one selector and one renderer.
- `tests/worktree-boundary.bats:134`, `:211` the same mapping lookup asserted separately for `compaction-instructions` and `post-compact`.

### (c) Bogus or hollow, 105 tests

These assert prose, test the fixture, pin implementation wording, or check only exit status.

- `tests/build-command.bats:10-21` greps exact sentences out of `commands/build.md`.
- `tests/execution-backend-command.bats:5-20` repeats the same prose grep across `transit`, `build`, and `team` markdown.
- `tests/teach-command.bats:70-74` asserts one literal prose sentence exists in `commands/teach.md`.
- `tests/zero-trust-contract.bats:5-10` greps role template markdown for phrases.
- `tests/compile-context-skills.bats:57` asserts a removed feature stays absent and protects no current behavior.
- `tests/render-workflow-template.bats:357` pins source style, "no single-quoted strings", not behavior.

Command docs still need one structural guard. `scripts/command-contract.sh` already validates frontmatter, required headings, referenced paths, and gated tools. `tests/command-contract.bats:295` runs it over the repository. Keep that test and delete the per-command prose greps.

## 3. Consolidation design

### Table-driven tests

Use one `@test` per production branch, with a case table for literals.

```bash
@test "qa_status classifies verification artifacts" {
  while IFS='|' read -r label artifact expected reason; do
    [ -n "$label" ] || continue
    build_phase "$artifact"
    run_phase_detect
    [ "$status" -eq 0 ] || { echo "case=$label status=$status" >&2; return 1; }
    echo "$output" | grep -q "^qa_status=$expected$" \
      || { echo "case=$label expected=$expected" >&2; echo "$output" >&2; return 1; }
    echo "$output" | grep -q "^qa_reason=$reason$" \
      || { echo "case=$label reason=$reason" >&2; echo "$output" >&2; return 1; }
  done <<'CASES'
pass-result|PASS|passed|none
legacy-pass|legacy|passed|none
fail-result|FAIL|failed|none
partial-result|PARTIAL|failed|none
missing|none|pending|missing_verification_artifact
CASES
}
```

Rules:

1. Merge only cases that enter the same production function and branch. Separate branches stay separate tests even when the input looks similar.
2. Every case prints its label and the actual output on failure. A table test that reports only "expected 0" is not acceptable.
3. Keep one assertion family per table. Do not put unrelated contracts in one loop.
4. Fixture builders replace repeated 10-line setup blocks. `tests/fixtures/` already has the phase-detect output builder.
5. Delete a test only when a retained table case covers its production branch.

### Merge map for the largest files

| File | From | To | Merge strategy |
|---|---:|---:|---|
| phase-detect | 151 | 25 | qa_status cases, UAT routing cases, discussion cases, milestone cases, basic states |
| compile-verify-context | 75 | 15 | scope selection, remediation kind, deviation extraction, FAIL history, known issues |
| debug-session-state | 54 | 12 | lifecycle, legacy migration, self-heal, readonly shell variables |
| agent-generator | 41 | 12 | schema 3 flags, contract validation, exclusive admission, pair/trio |
| team-command | 41 | 12 | preflight, prepare, spawn-payload, record/task, docs contract via command-contract |
| worktree-boundary | 39 | 8 | file-guard, compaction, post-compact, cleanup policy |
| qa-file-guard | 34 | 8 | role scope, contract allowance, symlink boundary, main delegation |
| qa-workflow-spawn-guard | 33 | 5 | manifest validation, scriptPath, digest, registration, authoring verbs moved to command-contract |
| task-contract | 31 | 10 | open, state, issue, schema 2/3, snapshot assert |
| context-cache | 27 | 4 | hash stability, fingerprint sensitivity, cache hit/miss, index |
| resolve-agent-settings | 25 | 4 | route resolution, reasoning, max_turns, renderer |
| phase-detect-output-contract | 11 | 0 | Move the 4 unique cases into the phase-detect table, delete the rest |

Projected total is **425 tests**, a 73 percent reduction from 1589. All 932 keep behaviors and all 552 duplicate cases remain as rows or assertions. This plan removes the 105 bogus tests.

## 4. Coverage measurement

Tool status on this host.

| Tool | Status |
|---|---|
| `kcov` | Not installed. `brew info kcov` reports stable 43, dependencies `dwarfutils` and `openssl@4`. |
| `bashcov` | Not installed. No `bashcov` gem. |
| `pytest` | Installed, version 9.1.1 at `/opt/homebrew/bin/pytest`. This corrects the earlier assumption that pytest was absent. |
| `coverage` (Python) | Not installed. `python3 -m coverage` fails with `No module named coverage`. |

Install kcov, do not run the install as part of this step.

```bash
brew install kcov
```

Capture baseline before any test edit. Include both production trees.

```bash
cd /Users/michael/Development/projects/meridian
env -u CDPATH kcov --bash-method=DEBUG \
  --include-path="$PWD/scripts" \
  --include-path="$PWD/hooks" \
  --include-pattern='\.(sh|py)$' \
  /tmp/meridian-kcov-before \
  bats tests/
```

Extract per-file line coverage.

```bash
jq -r '.files[] | "\(.file)\t\(.percent_covered)"' \
  /tmp/meridian-kcov-before/coverage.json | sort > /tmp/kcov-before.tsv
```

Repeat after each consolidation batch into `/tmp/meridian-kcov-after` and compare.

```bash
jq -r '.files[] | "\(.file)\t\(.percent_covered)"' \
  /tmp/meridian-kcov-after/coverage.json | sort > /tmp/kcov-after.tsv
diff -u /tmp/kcov-before.tsv /tmp/kcov-after.tsv
```

Gate. No file under `scripts/` or `hooks/` loses more than 0.5 percentage points of line coverage, and total line coverage does not fall. A file that loses coverage means a production branch lost its last case, so reject the batch.

Caveats.

- `kcov` supports bash through the DEBUG trap. If line data is empty, retry with `--bash-method=PS4`.
- The full suite ends normally now, but a CDPATH-bearing shell can still hang it. Always run the coverage command with `env -u CDPATH`.
- kcov covers Python hooks only if the Python coverage plugin is present. For hooks, install `coverage` and use `python -m coverage run -m pytest hooks/test_*.py` plus `python -m coverage report`. `hooks/scope_guard.py` is production code despite its `test_` prefix, so `python -m unittest discover hooks` picks it up and errors. Name the real hook test modules explicitly and do not rename that file.
- If kcov is unavailable, use `gem install bashcov simplecov` and `bashcov --root "$PWD" -- bats tests/` as the fallback. Its `.resultset.json` is harder to diff, so prefer kcov.

## 5. Failure triage

The raw run produced 63 not ok. The deterministic run with `env -u CDPATH` produced 22 not ok. Therefore the exported `CDPATH` in this shell causes 41 failures. `CDPATH` makes `cd` echo the target path, so every `$(cd ... && pwd -P)` capture gains an extra line and corrupts the result.

| Cluster | Tests | Root cause | Verdict |
|---|---:|---|---|
| context-cache, context-index | 233-262, 22 tests | `cache-context.sh` and `compile-context.sh` resolve planning and plan paths with `cd && pwd -P`. `CDPATH` adds a path line. A run with `env -u CDPATH` passes all 27 context-cache tests. | Test environment and production path helper fragility |
| phase-detect qa_status | 766-805, 13 tests | `track-known-issues.sh:41` captures `cd "$PHASE_DIR" && pwd -P`. With `CDPATH`, `PHASE_DIR` becomes two lines and `PLANNING_DIR` resolution fails, so the gate returns `known_issues_status=probe_error` and `REMEDIATION_REQUIRED`. A single-test run with `env -u CDPATH` passes. | Test environment and production path helper fragility |
| team-command preflight and prepare | 1257-1274, 15 tests | Two causes. Preflight tests inherit `TMUX` and also read the host catalog, so they fail on pane resolution or `ARG_MAX`. Prepare tests hit `compose-model-catalog.sh:43: /usr/bin/jq: Argument list too long` because the host catalog is passed as `--argjson lines`. Tests with a small seeded catalog pass. | Production bug (`ARG_MAX`) plus ambient `TMUX` in tests |
| tmux watchdog | 1300, 1301, 1304 | Check exits 1 but the bound agent does not reach `state=shutdown`. Reproduced with `env -u CDPATH`, so not path-related. | Production behavior failure |
| session-stop and doctor-cleanup worktrees | 1497, 1511 | Same `CDPATH` path corruption. Both pass with `env -u CDPATH`. | Test environment |
| 109 Claude Code catalog | 109 | `compose-model-catalog.sh:43` passes the extracted host catalog as a single argv value. On this host the catalog exceeds `ARG_MAX`. | Production bug |
| 137 compile-context telemetry | 137 | CDPATH path corruption in the metrics run. Passes alone with `env -u CDPATH`. | Test environment |
| 403 doctor preflight helper | 403 | The test runs the preflight helper without clearing `TMUX`. Inside this tmux session the fake tmux cannot resolve a pane, so preflight fails. | Stale environment-coupled test |
| 667, 717 output contract | phase-detect-output-contract.bats:84, phase-detect.bats:1104 | CDPATH path corruption. Both pass with `env -u CDPATH`. | Test environment |
| 857 probe-map-tools | 122 | CDPATH path corruption. Passes with `env -u CDPATH`. | Test environment |
| 1187 statusline outside tmux | 211 | The test does not unset `TMUX`, so inside this tmux session the statusline takes the tmux branch and omits the standard contract. | Stale environment-coupled test |
| 1356 attached tmux teardown | 557 | The test hardcodes `session:0.0`. This host's tmux config uses `base-index 1`, so `send-keys` fails with `can't find window: 0`. | Stale test, hardcoded tmux index |

Do not treat the 41 CDPATH failures as test debt alone. Production scripts still mishandle an exported `CDPATH`, so add one explicit test for `CDPATH` robustness and clear it in the shared test setup. Do not change production code in this step.

## 6. Post-suite hang

Not reproducible on the current tree. Two full runs reached test 1589 and exited normally, one with `CDPATH` exported and one with `env -u CDPATH`. The CDPATH run produced 65 not ok (63 baseline plus two failures from concurrent production edits) and printed `exit=1`.

Evidence.

- No suspect file hangs when run alone, with or without `CDPATH`. All tmux, lock, model, session, and worktree files exited.
- A combined tmux group run under `CDPATH` exited with failures.
- The earlier hang is therefore not attributable to a current test in a deterministic way.

The only test that structurally leaves a detached process is `tests/tmux-orchestrator.bats:523`. It creates a detached tmux session and fails at line 557 on the hardcoded `session:0.0`, so it never sends the kill script. Teardown kills the server, but a pane shell or a login-profile child can outlive it on some hosts and hold the bats capture pipe. Treat that test as the prime suspect if the hang returns, and fix its window-index lookup and teardown. Do not delete tests on the basis of the old hang alone.

## 7. Risks

1. `CDPATH` masks real failures. 41 of 63 raw failures vanish with `env -u CDPATH`. Consolidation run without that guard will chase false reds and may delete valid tests.
2. Table-driven tests can hide case identity. Every case must print its label and input on failure, otherwise a green table can cover a broken branch.
3. Deleting prose tests removes the only guard against command-document drift. `command-contract.sh` covers structure, not semantic correctness. Keep the repository-wide contract test, and accept that no test will pin prose changes.
4. Ambient tmux state makes three tests environment-dependent. Clear `TMUX` and `TMUX_PANE` for non-tmux tests, and query `#{window_index}` instead of hardcoding `:0.0`.
5. The plan cannot prove coverage until it installs kcov or bashcov. Without a baseline, a merge can silently drop a branch and no one will see it.
6. The 22 genuine failures include at least two production bugs. Consolidation must not delete the failing tests before fixing the bugs, or the bugs become invisible.
7. The working tree changed outside this analysis during measurement. The changed path count grew from 27 at 13:00 to 43 at 13:07, including `scripts/verification-freshness.sh`, `scripts/session-start.sh`, and `hooks/scope_guard.py`. Re-run failure counts after the tree stabilizes.

## 8. Execution tasks

Each task touches at most three test files. Verification assumes `env -u CDPATH`. Count columns are for the files in that task. Target is the expected final `@test` count for the task.

| Task | Files | Tests | Keep | Merge | Delete | Target | Verification |
|---|---|---:|---:|---:|---:|---:|---|
| G0 baseline coverage | none | 0 | 0 | 0 | 0 | 0 | Run the kcov command in section 4, save `/tmp/meridian-kcov-before` |
| G1 harness and statusline | test_helper.bash, statusline.bats | 12 | 9 | 3 | 0 | 5 | `env -u CDPATH bats tests/statusline.bats`, then one full-suite run |
| G2 prose delete | build-command.bats, debug-command.bats, fix-command.bats | 21 | 1 | 0 | 20 | 0 | `bats tests/command-contract.bats` |
| G3 prose delete | init-command.bats, map-command.bats, qa-command.bats | 19 | 2 | 0 | 17 | 2 | `bats tests/init-command.bats tests/map-command.bats` |
| G4 prose delete | research-command.bats, transit-command.bats, teach-command.bats | 24 | 1 | 0 | 23 | 1 | `bats tests/research-command.bats` |
| G5 prose delete | model-config-commands.bats, import-command.bats, execution-backend-command.bats | 11 | 0 | 0 | 11 | 0 | `bats tests/command-contract.bats` |
| G6 prose delete | init-import-routing.bats, transit-import-routing.bats, workflow-spawn-protocol.bats | 11 | 0 | 0 | 11 | 0 | `bats tests/command-contract.bats` |
| G7 doc contracts | zero-trust-contract.bats, compile-context-skills.bats, clean-stale-teams.bats | 15 | 4 | 0 | 11 | 2 | `bats tests/clean-stale-teams.bats` |
| G8 phase detect | phase-detect.bats | 151 | 60 | 91 | 0 | 25 | `bats tests/phase-detect.bats`, tail reports `1..25` |
| G9 cache | context-cache.bats, context-index.bats, context-usage.bats | 45 | 18 | 27 | 0 | 7 | `bats tests/context-cache.bats tests/context-usage.bats` |
| G10 output contract | phase-detect-output-contract.bats | 11 | 11 | 0 | 0 | 0 | `bats tests/phase-detect.bats`, then remove the file |
| G11 verify context | compile-verify-context.bats | 75 | 30 | 45 | 0 | 15 | `bats tests/compile-verify-context.bats`, tail reports `1..15` |
| G12 debug state | debug-session-state.bats | 54 | 24 | 30 | 0 | 12 | `bats tests/debug-session-state.bats`, tail reports `1..12` |
| G13 team | team-command.bats, team-context-index.bats, team-run-state.bats | 60 | 41 | 9 | 10 | 19 | `bats tests/team-command.bats tests/team-context-index.bats tests/team-run-state.bats` |
| G14 agents | agent-generator.bats, agent-lifecycle.bats, agent-routing-evidence.bats | 55 | 39 | 16 | 0 | 18 | `bats tests/agent-generator.bats tests/agent-lifecycle.bats tests/agent-routing-evidence.bats` |
| G15 worktrees | worktree-boundary.bats, worktree.bats | 64 | 32 | 32 | 0 | 13 | `bats tests/worktree-boundary.bats tests/worktree.bats` |
| G16 qa guards | qa-file-guard.bats, qa-bash-guard.bats, qa-agent-spawn-guard.bats | 71 | 45 | 26 | 0 | 18 | `bats tests/qa-file-guard.bats tests/qa-bash-guard.bats tests/qa-agent-spawn-guard.bats` |
| G17 contract and gate | qa-workflow-spawn-guard.bats, command-contract.bats, qa-gate.bats | 66 | 42 | 24 | 0 | 18 | `bats tests/qa-workflow-spawn-guard.bats tests/command-contract.bats tests/qa-gate.bats` |
| G18 task contract | task-contract.bats, task-hooks.bats, workflow-manifest.bats | 47 | 32 | 15 | 0 | 18 | `bats tests/task-contract.bats tests/task-hooks.bats tests/workflow-manifest.bats` |
| G19 research | research-session-state.bats, compile-research-context.bats | 48 | 24 | 24 | 0 | 13 | `bats tests/research-session-state.bats tests/compile-research-context.bats` |
| G20 models | claude-capabilities.bats, host-agent-enum.bats, meridian-model.bats | 60 | 41 | 19 | 0 | 18 | `bats tests/claude-capabilities.bats tests/host-agent-enum.bats tests/meridian-model.bats` |
| G21 todos | todo-lifecycle.bats, todo-details.bats, list-todos.bats | 55 | 34 | 21 | 0 | 16 | `bats tests/todo-lifecycle.bats tests/todo-details.bats tests/list-todos.bats` |
| G22 tmux bus | tmux-bus.bats, tmux-bus-watchdog.bats, tmux-preflight.bats | 35 | 27 | 8 | 0 | 13 | `bats tests/tmux-bus.bats tests/tmux-bus-watchdog.bats tests/tmux-preflight.bats` |
| G23 tmux orchestration | tmux-orchestrator.bats, tmux-spawn-group.bats, session-start.bats | 45 | 32 | 13 | 0 | 16 | `bats tests/tmux-orchestrator.bats tests/tmux-spawn-group.bats tests/session-start.bats` |
| G24 routing | meridian-routing.bats, meridian-routing-lock.bats, meridian-execution-config.bats | 60 | 40 | 20 | 0 | 18 | `bats tests/meridian-routing.bats tests/meridian-routing-lock.bats tests/meridian-execution-config.bats` |
| G25 config | meridian-config.bats, meridian-conventions.bats, meridian-skills.bats | 66 | 43 | 23 | 0 | 19 | `bats tests/meridian-config.bats tests/meridian-conventions.bats tests/meridian-skills.bats` |
| G26 settings and snapshot | resolve-agent-settings.bats, runtime-snapshot.bats | 45 | 23 | 22 | 0 | 10 | `bats tests/resolve-agent-settings.bats tests/runtime-snapshot.bats` |
| G27 writers | write-verification.bats, write-debug-session.bats, session-telemetry.bats | 51 | 30 | 21 | 0 | 15 | `bats tests/write-verification.bats tests/write-debug-session.bats tests/session-telemetry.bats` |
| G28 remediation | remediation-round.bats, uat-remediation-helpers.bats, verify-state-consistency.bats | 32 | 24 | 8 | 0 | 11 | `bats tests/remediation-round.bats tests/uat-remediation-helpers.bats tests/verify-state-consistency.bats` |
| G29 plans and rtk | plan-import.bats, plan-task-count.bats, rtk-manager.bats | 41 | 31 | 10 | 0 | 15 | `bats tests/plan-import.bats tests/plan-task-count.bats tests/rtk-manager.bats` |
| G30 maps | indexer-sync.bats, probe-map-tools.bats, map-staleness.bats | 29 | 19 | 10 | 0 | 9 | `bats tests/indexer-sync.bats tests/probe-map-tools.bats tests/map-staleness.bats` |
| G31 result gate | qa-result-gate.bats, frontmatter-array-parser.bats, validate-commit.bats | 28 | 21 | 7 | 0 | 9 | `bats tests/qa-result-gate.bats tests/frontmatter-array-parser.bats tests/validate-commit.bats` |
| G32 security and deviq | security-filter.bats, deviq-lookup.bats, deviq-nudge.bats | 25 | 25 | 0 | 0 | 8 | `bats tests/security-filter.bats tests/deviq-lookup.bats tests/deviq-nudge.bats` |
| G33 deviq and release | deviq-gate.bats, deviq-digest-append.bats, version-release.bats | 15 | 15 | 0 | 0 | 7 | `bats tests/deviq-gate.bats tests/deviq-digest-append.bats tests/version-release.bats` |
| G34 roots | control-root.bats, plugin-root.bats, hook-wrapper.bats | 12 | 12 | 0 | 0 | 6 | `bats tests/control-root.bats tests/plugin-root.bats tests/hook-wrapper.bats` |
| G35 questions | user-question-cancel.bats, infer-project-context.bats, track-known-issues.bats | 10 | 10 | 0 | 0 | 6 | `bats tests/user-question-cancel.bats tests/infer-project-context.bats tests/track-known-issues.bats` |
| G36 metadata | marketplace.bats, help-output.bats, telemetry-report.bats | 4 | 4 | 0 | 0 | 3 | `bats tests/marketplace.bats tests/help-output.bats tests/telemetry-report.bats` |
| G37 format and delta | check-markdown-format.bats, bootstrap-archive-helpers.bats, delta-context.bats | 23 | 19 | 4 | 0 | 9 | `bats tests/check-markdown-format.bats tests/bootstrap-archive-helpers.bats tests/delta-context.bats` |
| G38 debug start | extract-skill-follow-up-files.bats, debug-start-selected-todo.bats, debug-start-manual.bats | 38 | 27 | 11 | 0 | 13 | `bats tests/extract-skill-follow-up-files.bats tests/debug-start-selected-todo.bats tests/debug-start-manual.bats` |
| G39 doctor and tiers | doctor.bats, map-tiers.bats, render-workflow-template-gate-loop.bats | 30 | 22 | 8 | 0 | 10 | `bats tests/doctor.bats tests/map-tiers.bats tests/render-workflow-template-gate-loop.bats` |
| G40 template and compile | render-workflow-template.bats, compile-context.bats | 25 | 18 | 5 | 2 | 8 | `bats tests/render-workflow-template.bats tests/compile-context.bats` |

After each task, re-run the kcov command from section 4 into a fresh directory and diff the per-file table. Reject a task that loses coverage in any file. After all tasks, run the full suite once with `env -u CDPATH bats tests/` and confirm the total is below 500 and no new failure appears.