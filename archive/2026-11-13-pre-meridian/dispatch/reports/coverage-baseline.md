# Coverage baseline

Measured with `scripts/dev/coverage.sh run` on the tree at `362a292`. kcov 1.14 gives line coverage for scripts/, coverage.py gives line and branch coverage for hooks/. The run uses bats 1.14.0 in a Linux container as a non-root user.


## Totals

| Area | Covered | Total | Percent |
|---|---|---|---|
| Bash lines (scripts/, traced files only) | 14981 | 22309 | 67.15 |
| Python hook lines | 1291 | 1391 | 92.81 |
| Python hook branches | 411 | 467 | 88.01 |

The bash total covers 226 files that kcov traced. kcov never traced 42 more scripts, so they are absent from the denominator and the real bash percentage is lower than shown. The last section lists them.


## Gap to the 90 percent target in scripts/

Bash line coverage is 67.15 percent against a target of at least 90 percent. Reaching 90 percent takes about 5098 more covered lines out of 22309, and 176 of 226 traced files sit below 90 percent. The untraced scripts widen the gap. Python hooks are at 92.81 percent lines, already above the target.


## Guard decision branches in hooks/

The target is 100 percent of allow and deny branches. Data comes from coverage.py `missing_branches` and `executed_branches`. The table covers the six hook modules that decide a call (message_scope_guard, scope_guard, skill_gate, user_question_guard, read_only_command and guard_paths). A branch counts as a guard decision when its target statement returns None (allow), exits 0, or emits or returns a denial. The classification is a text match on the target line with three manual corrections, so treat it as a working list. Tests cover 49 of the 69 decision branches and miss 20.

Uncovered decision branches:

| File | Branch (line to line) | Decision | Condition | Covered |
|---|---|---|---|---|
| hooks/guard_paths.py | 78 to 79 | allow | `if not isinstance(cwd, str) or not cwd:` | no |
| hooks/guard_paths.py | 81 to 86 | allow | `while current != current.parent:` | no |
| hooks/guard_paths.py | 121 to 122 | allow | `if any(char in value for char in UNRESOLVED_CHARS):` | no |
| hooks/message_scope_guard.py | 48 to 49 | allow | `if not identifier:` | no |
| hooks/message_scope_guard.py | 67 to 69 | deny | `if reason is None:` | no |
| hooks/skill_gate.py | 59 to 60 | allow | `if not isinstance(node, dict):` | no |
| hooks/skill_gate.py | 113 to 114 | allow | `if parent == current:` | no |
| hooks/skill_gate.py | 120 to 121 | allow | `if not root:` | no |
| hooks/skill_gate.py | 180 to 182 | allow | `if role in PLAN_ROLES:` | no |
| hooks/skill_gate.py | 216 to 218 | deny | `if reason is None:` | no |
| hooks/scope_guard.py | 41 to 42 | allow | `if not file_path or not _is_test_path(file_path):` | no |
| hooks/scope_guard.py | 44 to 45 | allow | `if not identifier:` | no |
| hooks/scope_guard.py | 47 to 48 | allow | `if role not in ENGINEER_ROLES:` | no |
| hooks/user_question_guard.py | 96 to 97 | allow | `if not isinstance(data, dict):` | no |
| hooks/user_question_guard.py | 184 to 186 | allow | `if tool_name == ASK_TOOL or _is_blocked_while_pending(tool_name):` | no |
| hooks/user_question_guard.py | 194 to 195 | allow | `if store is None:` | no |
| hooks/user_question_guard.py | 225 to 227 | allow | `if isinstance(answer, str) and not _is_error_payload(data):` | no |
| hooks/user_question_guard.py | 238 to 239 | allow | `if data.get("tool_name") != ASK_TOOL:` | no |
| hooks/user_question_guard.py | 273 to 274 | allow | `if planning_dir is None or not isinstance(prompt, str) or not prompt.strip():` | no |
| hooks/user_question_guard.py | 284 to 285 | allow | `if planning_dir is None:` | no |

All decision branches:

| File | Branch (line to line) | Decision | Condition | Covered |
|---|---|---|---|---|
| hooks/guard_paths.py | 78 to 79 | allow | `if not isinstance(cwd, str) or not cwd:` | no |
| hooks/guard_paths.py | 81 to 86 | allow | `while current != current.parent:` | no |
| hooks/guard_paths.py | 121 to 122 | allow | `if any(char in value for char in UNRESOLVED_CHARS):` | no |
| hooks/message_scope_guard.py | 48 to 49 | allow | `if not identifier:` | no |
| hooks/message_scope_guard.py | 67 to 69 | deny | `if reason is None:` | no |
| hooks/skill_gate.py | 59 to 60 | allow | `if not isinstance(node, dict):` | no |
| hooks/skill_gate.py | 113 to 114 | allow | `if parent == current:` | no |
| hooks/skill_gate.py | 120 to 121 | allow | `if not root:` | no |
| hooks/skill_gate.py | 180 to 182 | allow | `if role in PLAN_ROLES:` | no |
| hooks/skill_gate.py | 216 to 218 | deny | `if reason is None:` | no |
| hooks/scope_guard.py | 41 to 42 | allow | `if not file_path or not _is_test_path(file_path):` | no |
| hooks/scope_guard.py | 44 to 45 | allow | `if not identifier:` | no |
| hooks/scope_guard.py | 47 to 48 | allow | `if role not in ENGINEER_ROLES:` | no |
| hooks/user_question_guard.py | 96 to 97 | allow | `if not isinstance(data, dict):` | no |
| hooks/user_question_guard.py | 184 to 186 | allow | `if tool_name == ASK_TOOL or _is_blocked_while_pending(tool_name):` | no |
| hooks/user_question_guard.py | 194 to 195 | allow | `if store is None:` | no |
| hooks/user_question_guard.py | 225 to 227 | allow | `if isinstance(answer, str) and not _is_error_payload(data):` | no |
| hooks/user_question_guard.py | 238 to 239 | allow | `if data.get("tool_name") != ASK_TOOL:` | no |
| hooks/user_question_guard.py | 273 to 274 | allow | `if planning_dir is None or not isinstance(prompt, str) or not prompt.strip():` | no |
| hooks/user_question_guard.py | 284 to 285 | allow | `if planning_dir is None:` | no |
| hooks/guard_paths.py | 71 to 72 | allow | `if not (candidate.exists() or candidate.is_symlink()):` | yes |
| hooks/guard_paths.py | 83 to 85 | allow | `if found is not None:` | yes |
| hooks/guard_paths.py | 121 to 121 | allow | `if any(char in value for char in UNRESOLVED_CHARS):` | yes |
| hooks/guard_paths.py | 195 to -181 | allow | `return any(_value_hit(item, Path(root), scoped) for item in expand_braces(pattern))` | yes |
| hooks/message_scope_guard.py | 38 to 39 | allow | `if error:` | yes |
| hooks/message_scope_guard.py | 42 to 43 | allow | `if (data.get("tool_name") or "") != "SendMessage":` | yes |
| hooks/message_scope_guard.py | 45 to 46 | allow | `if recipient != MAIN_RECIPIENT:` | yes |
| hooks/message_scope_guard.py | 53 to 54 | allow | `if role is None or _may_report_to_main(entry, role):` | yes |
| hooks/message_scope_guard.py | 56 to 57 | deny | `if not pair_id:` | yes |
| hooks/message_scope_guard.py | 56 to 58 | deny | `if not pair_id:` | yes |
| hooks/message_scope_guard.py | 67 to 68 | deny | `if reason is None:` | yes |
| hooks/read_only_command.py | 72 to 73 | allow | `if pattern is None:` | yes |
| hooks/skill_gate.py | 37 to 42 | allow | `if (not isinstance(data, dict)` | yes |
| hooks/skill_gate.py | 37 to 42 | allow | `if (not isinstance(data, dict)` | yes |
| hooks/skill_gate.py | 58 to 59 | allow | `for key in path:` | yes |
| hooks/skill_gate.py | 66 to 70 | allow | `for path in CANDIDATE_ID_PATHS:` | yes |
| hooks/skill_gate.py | 68 to 69 | allow | `if value:` | yes |
| hooks/skill_gate.py | 158 to 159 | deny | `if requirement == "architecture":` | yes |
| hooks/skill_gate.py | 158 to 162 | deny | `if requirement == "architecture":` | yes |
| hooks/skill_gate.py | 180 to 181 | allow | `if role in PLAN_ROLES:` | yes |
| hooks/skill_gate.py | 187 to 188 | allow | `if error:` | yes |
| hooks/skill_gate.py | 192 to 193 | allow | `if not identifier:` | yes |
| hooks/skill_gate.py | 198 to 199 | allow | `if _record_read(state_key, identifier, tool_name, tool_input):` | yes |
| hooks/skill_gate.py | 198 to 200 | allow | `if _record_read(state_key, identifier, tool_name, tool_input):` | yes |
| hooks/skill_gate.py | 200 to 201 | allow | `if tool_name not in WRITE_TOOLS:` | yes |
| hooks/skill_gate.py | 205 to 206 | deny | `if requirement is None or _has_satisfied(state_key, identifier, requirement):` | yes |
| hooks/skill_gate.py | 205 to 207 | deny | `if requirement is None or _has_satisfied(state_key, identifier, requirement):` | yes |
| hooks/skill_gate.py | 216 to 217 | deny | `if reason is None:` | yes |
| hooks/scope_guard.py | 33 to 34 | allow | `if error:` | yes |
| hooks/scope_guard.py | 38 to 39 | allow | `if tool_name not in WRITE_TOOLS:` | yes |
| hooks/scope_guard.py | 47 to 49 | deny | `if role not in ENGINEER_ROLES:` | yes |
| hooks/scope_guard.py | 58 to 59 | deny | `if reason is None:` | yes |
| hooks/scope_guard.py | 58 to 60 | deny | `if reason is None:` | yes |
| hooks/user_question_guard.py | 103 to 104 | allow | `if isinstance(value, str) and SESSION_PATTERN.fullmatch(value):` | yes |
| hooks/user_question_guard.py | 103 to 105 | allow | `if isinstance(value, str) and SESSION_PATTERN.fullmatch(value):` | yes |
| hooks/user_question_guard.py | 109 to 113 | allow | `for key in keys:` | yes |
| hooks/user_question_guard.py | 111 to 112 | allow | `if isinstance(value, str) and value:` | yes |
| hooks/user_question_guard.py | 164 to 169 | allow | `if _agent_identifier(data):` | yes |
| hooks/user_question_guard.py | 178 to 179 | allow | `if tool_name == ASK_TOOL:` | yes |
| hooks/user_question_guard.py | 178 to 180 | allow | `if tool_name == ASK_TOOL:` | yes |
| hooks/user_question_guard.py | 184 to 185 | allow | `if tool_name == ASK_TOOL or _is_blocked_while_pending(tool_name):` | yes |
| hooks/user_question_guard.py | 205 to 208 | allow | `for container in (data.get("tool_response"), data.get("tool_input"), data):` | yes |
| hooks/user_question_guard.py | 206 to 207 | allow | `if isinstance(container, dict) and isinstance(container.get("answers"), dict):` | yes |
| hooks/user_question_guard.py | 222 to 223 | allow | `if answers is None or error is not None or record is None:` | yes |
| hooks/user_question_guard.py | 225 to 226 | allow | `if isinstance(answer, str) and not _is_error_payload(data):` | yes |
| hooks/user_question_guard.py | 242 to 243 | allow | `if store.state(session_id) not in ACTIVE_STATUSES:` | yes |
| hooks/user_question_guard.py | 256 to 258 | allow | `if status == "cancelled":` | yes |
| hooks/user_question_guard.py | 258 to 259 | allow | `if status != "awaiting_freeform":` | yes |
| hooks/user_question_guard.py | 292 to 299 | allow | `if store.state(cast(str, session_id)) in ACTIVE_STATUSES:` | yes |

## Per-file coverage, weakest first

### Python hooks

| File | Lines covered | Lines | Line % | Branches covered | Branches | Branch % |
|---|---|---|---|---|---|---|
| hooks/context_usage.py | 46 | 58 | 79.31 | 10 | 16 | 62.50 |
| hooks/scope_guard.py | 37 | 45 | 82.22 | 12 | 16 | 75.00 |
| hooks/message_scope_guard.py | 42 | 50 | 84.00 | 18 | 22 | 81.82 |
| hooks/decision_io.py | 47 | 54 | 87.04 | 7 | 10 | 70.00 |
| hooks/skill_gate.py | 132 | 149 | 88.59 | 47 | 56 | 83.93 |
| hooks/user_question_guard.py | 213 | 231 | 92.21 | 61 | 72 | 84.72 |
| hooks/path_identity.py | 96 | 104 | 92.31 | 36 | 38 | 94.74 |
| hooks/decision_layout.py | 45 | 48 | 93.75 | 11 | 14 | 78.57 |
| hooks/guard_paths.py | 173 | 182 | 95.05 | 86 | 92 | 93.48 |
| hooks/brace_expansion.py | 78 | 82 | 95.12 | 34 | 38 | 89.47 |
| hooks/read_only_command.py | 109 | 113 | 96.46 | 49 | 51 | 96.08 |
| hooks/decision_store.py | 99 | 101 | 98.02 | 20 | 22 | 90.91 |
| hooks/__init__.py | 0 | 0 | 100.00 | 0 | 0 | 100.00 |
| hooks/decision_common.py | 32 | 32 | 100.00 | 4 | 4 | 100.00 |
| hooks/decision_records.py | 73 | 73 | 100.00 | 6 | 6 | 100.00 |
| hooks/question_validation.py | 69 | 69 | 100.00 | 10 | 10 | 100.00 |

### Bash scripts

| File | Lines covered | Lines | Line % |
|---|---|---|---|
| scripts/lib/suggest-next-build.sh | 5 | 106 | 4.72 |
| scripts/lib/uat-deviation-insert.sh | 3 | 59 | 5.08 |
| scripts/lib/suggest-next-verify.sh | 4 | 58 | 6.90 |
| scripts/lib/suggest-next-review.sh | 15 | 117 | 12.82 |
| scripts/reconcile-state-md.sh | 44 | 302 | 14.57 |
| scripts/extract-uat-resume.sh | 26 | 176 | 14.77 |
| scripts/lib/uat-deviation-fields.sh | 6 | 40 | 15.00 |
| scripts/lib/uat-deviation-registry.sh | 15 | 88 | 17.05 |
| scripts/normalize-plan-filenames.sh | 34 | 198 | 17.17 |
| scripts/state-updater.sh | 10 | 58 | 17.24 |
| scripts/finalize-uat-status.sh | 25 | 140 | 17.86 |
| scripts/phase-state-utils.sh | 5 | 24 | 20.83 |
| scripts/lib/validate-uat-remediation-checks.sh | 23 | 107 | 21.50 |
| scripts/lib/qa-result-gate-git-evidence.sh | 17 | 75 | 22.67 |
| scripts/lib/validate-uat-remediation-paths.sh | 21 | 85 | 24.71 |
| scripts/lib/shell-quote-decode.sh | 14 | 56 | 25.00 |
| scripts/resolve-artifact-path.sh | 20 | 78 | 25.64 |
| scripts/lib/qa-result-gate-known-issues.sh | 43 | 154 | 27.92 |
| scripts/lib/qa-result-gate-fail-classifications.sh | 67 | 228 | 29.39 |
| scripts/uat-remediation-state.sh | 62 | 207 | 29.95 |
| scripts/lib/phase-state-dirs.sh | 32 | 106 | 30.19 |
| scripts/generate-gsd-index.sh | 10 | 33 | 30.30 |
| scripts/derive-milestone-slug.sh | 32 | 102 | 31.37 |
| scripts/lib/suggest-next-helpers.sh | 21 | 64 | 32.81 |
| scripts/lib/qa-result-gate-summary-deviations.sh | 67 | 201 | 33.33 |
| scripts/lib/known-issues-sync.sh | 25 | 74 | 33.78 |
| scripts/bootstrap/bootstrap-state.sh | 63 | 186 | 33.87 |
| scripts/update-phase-total.sh | 70 | 187 | 37.43 |
| scripts/lib/uat-remediation-init.sh | 48 | 128 | 37.50 |
| scripts/plan-task-count.sh | 24 | 64 | 37.50 |
| scripts/team-command-transaction.sh | 94 | 244 | 38.52 |
| scripts/track-uat-deviations.sh | 18 | 46 | 39.13 |
| scripts/lib/suggest-next-state.sh | 97 | 244 | 39.75 |
| scripts/import-adapters/lib.sh | 15 | 36 | 41.67 |
| scripts/lib/team-command-transaction-roster.sh | 21 | 50 | 42.00 |
| scripts/validate-uat-remediation-artifact.sh | 22 | 52 | 42.31 |
| scripts/lib/todo-lifecycle-snapshot.sh | 97 | 222 | 43.69 |
| scripts/lib/list-todos-functions.inc | 56 | 127 | 44.09 |
| scripts/lib/meridian-conventions-render.sh | 15 | 32 | 46.88 |
| scripts/extract-uat-issues.sh | 56 | 117 | 47.86 |
| scripts/lib/tmux-agent-orchestrator-teardown.sh | 62 | 127 | 48.82 |
| scripts/debug-start-manual.sh | 33 | 67 | 49.25 |
| scripts/lib/meridian-model-show.sh | 34 | 69 | 49.28 |
| scripts/summary-utils.sh | 106 | 213 | 49.77 |
| scripts/lib/require-bash.sh | 2 | 4 | 50.00 |
| scripts/migrate-config.sh | 87 | 169 | 51.48 |
| scripts/lib/tmux-agent-orchestrator-validate.sh | 52 | 98 | 53.06 |
| scripts/lib/phase-state-roadmap.sh | 138 | 257 | 53.70 |
| scripts/post-compact.sh | 28 | 52 | 53.85 |
| scripts/lib/resolve-verification-path-phase.sh | 20 | 37 | 54.05 |
| scripts/lib/compile-context-emit.sh | 78 | 144 | 54.17 |
| scripts/compaction-instructions.sh | 39 | 71 | 54.93 |
| scripts/normalize-prefer-teams.sh | 10 | 18 | 55.56 |
| scripts/workflow-generator.sh | 150 | 261 | 57.47 |
| scripts/lib/qa-result-gate-verification.sh | 38 | 66 | 57.58 |
| scripts/compile-verify-context-for-uat.sh | 14 | 24 | 58.33 |
| scripts/lib/agent-manifest.sh | 34 | 58 | 58.62 |
| scripts/resolve-todo-item.sh | 34 | 58 | 58.62 |
| scripts/lib/todo-item-metadata.sh | 67 | 114 | 58.77 |
| scripts/lib/compile-verify-context-plans.sh | 120 | 203 | 59.11 |
| scripts/lib/known-issues-registry.sh | 22 | 37 | 59.46 |
| scripts/doctor-cleanup.sh | 108 | 174 | 62.07 |
| scripts/list-todos.sh | 15 | 24 | 62.50 |
| scripts/resolve-plugin-root.sh | 25 | 40 | 62.50 |
| scripts/uat-utils.sh | 186 | 297 | 62.63 |
| scripts/lib/deviq-digest.sh | 22 | 35 | 62.86 |
| scripts/command-contract.sh | 7 | 11 | 63.64 |
| scripts/lib/tmux-bus-envelope.sh | 56 | 88 | 63.64 |
| scripts/worktree-status.sh | 28 | 44 | 63.64 |
| scripts/create-remediation-phase.sh | 163 | 253 | 64.43 |
| scripts/lib/team-command-transaction-prepare.sh | 62 | 96 | 64.58 |
| scripts/task-admission-guard.sh | 34 | 52 | 65.38 |
| scripts/lib/meridian-statusline-state.sh | 59 | 90 | 65.56 |
| scripts/lib/meridian-conventions-artifact.sh | 26 | 39 | 66.67 |
| scripts/lib/meridian-routing-validate.sh | 42 | 63 | 66.67 |
| scripts/lib/qa-result-gate-path-evidence.sh | 119 | 178 | 66.85 |
| scripts/write-verification.sh | 263 | 390 | 67.44 |
| scripts/resolve-lsp.sh | 48 | 70 | 68.57 |
| scripts/debug-start-selected-todo.sh | 136 | 198 | 68.69 |
| scripts/resolve-uat-remediation-round-limit.sh | 69 | 100 | 69.00 |
| scripts/worktree-cleanup.sh | 49 | 71 | 69.01 |
| scripts/runtime-snapshot.sh | 135 | 195 | 69.23 |
| scripts/statusline-install.sh | 27 | 39 | 69.23 |
| scripts/import-adapters/gsd.sh | 52 | 75 | 69.33 |
| scripts/verification-freshness.sh | 50 | 72 | 69.44 |
| scripts/resolve-verification-path.sh | 16 | 23 | 69.57 |
| scripts/todo-lifecycle.sh | 144 | 205 | 70.24 |
| scripts/infer-project-context.sh | 100 | 142 | 70.42 |
| scripts/lib/qa-result-gate-routing.sh | 84 | 119 | 70.59 |
| scripts/lib/phase-detect-support.sh | 168 | 237 | 70.89 |
| scripts/verify-state-consistency.sh | 59 | 83 | 71.08 |
| scripts/lib/meridian-config-files.sh | 42 | 59 | 71.19 |
| scripts/qa-gate.sh | 45 | 63 | 71.43 |
| scripts/cache-context.sh | 109 | 151 | 72.19 |
| scripts/lib/compile-research-emit.sh | 34 | 47 | 72.34 |
| scripts/lib/meridian-model-identity.sh | 34 | 47 | 72.34 |
| scripts/lib/debug-session-fields.sh | 62 | 85 | 72.94 |
| scripts/tmux-doctor.sh | 82 | 112 | 73.21 |
| scripts/lib/tmux-agent-orchestrator-provision.sh | 58 | 79 | 73.42 |
| scripts/research-session-state.sh | 184 | 250 | 73.60 |
| scripts/detect-stack.sh | 83 | 112 | 74.11 |
| scripts/qa-remediation-state.sh | 162 | 218 | 74.31 |
| scripts/lib/debug-session-locate.sh | 108 | 145 | 74.48 |
| scripts/lib/compose-model-catalog.sh | 85 | 114 | 74.56 |
| scripts/agent-spawn-guard.sh | 156 | 209 | 74.64 |
| scripts/write-debug-session.sh | 256 | 341 | 75.07 |
| scripts/probe-map-tools.sh | 60 | 79 | 75.95 |
| scripts/cleanup-temporary-agent-runfiles.sh | 58 | 76 | 76.32 |
| scripts/claude-capabilities.sh | 184 | 241 | 76.35 |
| scripts/deviq-lookup.sh | 56 | 73 | 76.71 |
| scripts/lib/meridian-config-freeze.sh | 30 | 39 | 76.92 |
| scripts/lib/compile-verify-context-history.sh | 52 | 67 | 77.61 |
| scripts/lib/meridian-routing-platform.sh | 52 | 67 | 77.61 |
| scripts/lib/phase-detect-environment-output.sh | 52 | 67 | 77.61 |
| scripts/team-context-index.sh | 143 | 184 | 77.72 |
| scripts/pending-decision.sh | 7 | 9 | 77.78 |
| scripts/track-known-issues.sh | 21 | 27 | 77.78 |
| scripts/tmux-session-name.sh | 32 | 41 | 78.05 |
| scripts/suggest-next.sh | 25 | 32 | 78.12 |
| scripts/lib/debug-start-todo-match.sh | 68 | 87 | 78.16 |
| scripts/resolve-agent-settings.sh | 117 | 149 | 78.52 |
| scripts/help-output.sh | 66 | 84 | 78.57 |
| scripts/lib/tmux-runtime.sh | 132 | 168 | 78.57 |
| scripts/lib/todo-lifecycle-known-issues.sh | 120 | 152 | 78.95 |
| scripts/lib/plan-source-adapters.sh | 87 | 110 | 79.09 |
| scripts/worktree-agent-map.sh | 19 | 24 | 79.17 |
| scripts/ensure-plugin-root-link.sh | 27 | 34 | 79.41 |
| scripts/agent-lifecycle.sh | 192 | 241 | 79.67 |
| scripts/bootstrap/bootstrap-project.sh | 8 | 10 | 80.00 |
| scripts/deviq-build-gate.sh | 28 | 35 | 80.00 |
| scripts/tmux-preflight.sh | 57 | 71 | 80.28 |
| scripts/check-markdown-format.sh | 33 | 41 | 80.49 |
| scripts/lib/manifest-lock.sh | 62 | 77 | 80.52 |
| scripts/lib/qa-result-gate-path-resolve.sh | 153 | 190 | 80.53 |
| scripts/lib/agent-generator-generate.sh | 93 | 115 | 80.87 |
| scripts/lib/known-issues-promote.sh | 34 | 42 | 80.95 |
| scripts/tmux-bus-watchdog.sh | 126 | 155 | 81.29 |
| scripts/map-staleness.sh | 35 | 43 | 81.40 |
| scripts/task-completion-guard.sh | 31 | 38 | 81.58 |
| scripts/lib/workflow-manifest.sh | 85 | 104 | 81.73 |
| scripts/lib/meridian-conventions-commands.sh | 64 | 78 | 82.05 |
| scripts/lib/meridian-statusline-tmux.sh | 62 | 75 | 82.67 |
| scripts/import-adapters/markdown.sh | 39 | 47 | 82.98 |
| scripts/lib/qa-gate-decision.sh | 10 | 12 | 83.33 |
| scripts/lib/qa-result-gate-round-evidence.sh | 180 | 216 | 83.33 |
| scripts/lib/team-command-transaction-routing.sh | 45 | 54 | 83.33 |
| scripts/todo-details.sh | 132 | 158 | 83.54 |
| scripts/lib/meridian-conventions-files.sh | 41 | 49 | 83.67 |
| scripts/lib/meridian-config-agent-teams.sh | 72 | 86 | 83.72 |
| scripts/worktree-create.sh | 26 | 31 | 83.87 |
| scripts/extract-skill-follow-up-files.sh | 69 | 82 | 84.15 |
| scripts/lib/meridian-routing-ops.sh | 69 | 82 | 84.15 |
| scripts/lib/meridian-model-journal.sh | 33 | 39 | 84.62 |
| scripts/file-guard.sh | 168 | 198 | 84.85 |
| scripts/lib/meridian-target-root.sh | 101 | 119 | 84.87 |
| scripts/lib/compile-context-roles.sh | 73 | 86 | 84.88 |
| scripts/phase-detect.sh | 193 | 227 | 85.02 |
| scripts/lib/agent-generator-options.sh | 82 | 96 | 85.42 |
| scripts/lib/agent-fields.sh | 18 | 21 | 85.71 |
| scripts/lib/plan-import-stage.sh | 73 | 85 | 85.88 |
| scripts/compile-context.sh | 134 | 156 | 85.90 |
| scripts/lib/phase-detect-qa-routing.sh | 198 | 229 | 86.46 |
| scripts/lib/meridian-statusline-format.sh | 32 | 37 | 86.49 |
| scripts/tmux-spawn-group.sh | 117 | 135 | 86.67 |
| scripts/lib/qa-result-gate-round-contract.sh | 118 | 136 | 86.76 |
| scripts/lib/meridian-model-commit.sh | 33 | 38 | 86.84 |
| scripts/lib/debug-session-create.sh | 86 | 99 | 86.87 |
| scripts/lib/meridian-model-restore.sh | 43 | 49 | 87.76 |
| scripts/lib/meridian-model-refresh.sh | 58 | 66 | 87.88 |
| scripts/lib/phase-detect-milestone-recovery.sh | 179 | 203 | 88.18 |
| scripts/bash-guard.sh | 156 | 176 | 88.64 |
| scripts/meridian-config.sh | 74 | 83 | 89.16 |
| scripts/team-run-state.sh | 127 | 142 | 89.44 |
| scripts/lib/plan-import-render.sh | 115 | 128 | 89.84 |
| scripts/compile-verify-context.sh | 80 | 89 | 89.89 |
| scripts/session-start.sh | 98 | 109 | 89.91 |
| scripts/lib/map-tiers.sh | 27 | 30 | 90.00 |
| scripts/lib/plan-import-promote.sh | 102 | 113 | 90.27 |
| scripts/lib/meridian-control-root.sh | 96 | 106 | 90.57 |
| scripts/compile-research-context.sh | 49 | 54 | 90.74 |
| scripts/meridian-statusline.sh | 60 | 66 | 90.91 |
| scripts/lib/plan-import-source.sh | 70 | 77 | 90.91 |
| scripts/notification-log.sh | 10 | 11 | 90.91 |
| scripts/workflow-spawn-guard.sh | 52 | 57 | 91.23 |
| scripts/lib/meridian-routing-migrate.sh | 21 | 23 | 91.30 |
| scripts/lib/qa-result-gate-scope.sh | 120 | 131 | 91.60 |
| scripts/lib/meridian-routing-lock.sh | 112 | 122 | 91.80 |
| scripts/plan-import.sh | 45 | 49 | 91.84 |
| scripts/lib/meridian-settings.sh | 12 | 13 | 92.31 |
| scripts/worktree-merge.sh | 12 | 13 | 92.31 |
| scripts/lib/phase-detect-active-routing.sh | 218 | 236 | 92.37 |
| scripts/lib/agent-generator-roles.sh | 76 | 82 | 92.68 |
| scripts/delta-files.sh | 51 | 55 | 92.73 |
| scripts/lib/compile-verify-context-remediation.sh | 116 | 125 | 92.80 |
| scripts/meridian-conventions.sh | 39 | 42 | 92.86 |
| scripts/remediation-round.sh | 67 | 72 | 93.06 |
| scripts/validate-commit.sh | 41 | 44 | 93.18 |
| scripts/lib/agent-generator-render.sh | 57 | 61 | 93.44 |
| scripts/lib/resolve-caveman-level.sh | 29 | 31 | 93.55 |
| scripts/meridian-routing.sh | 75 | 80 | 93.75 |
| scripts/debug-session-state.sh | 32 | 34 | 94.12 |
| scripts/lib/agent-generator-contract.sh | 150 | 159 | 94.34 |
| scripts/lib/tmux-bus-claim.sh | 121 | 128 | 94.53 |
| scripts/lib/tmux-bus-publish.sh | 149 | 157 | 94.90 |
| scripts/lib/tmux-agent-orchestrator-split.sh | 115 | 121 | 95.04 |
| scripts/session-stop.sh | 21 | 22 | 95.45 |
| scripts/lib/debug-session-commands.sh | 132 | 138 | 95.65 |
| scripts/render-agent-template.sh | 101 | 105 | 96.19 |
| scripts/lib/resolve-verification-path-modes.sh | 51 | 53 | 96.23 |
| scripts/meridian-model | 112 | 116 | 96.55 |
| scripts/render-workflow-template.sh | 56 | 58 | 96.55 |
| scripts/deviq-nudge.sh | 39 | 40 | 97.50 |
| scripts/tmux-bus.sh | 39 | 40 | 97.50 |
| scripts/clean-stale-teams.sh | 47 | 48 | 97.92 |
| scripts/lib/meridian-config-ops.sh | 56 | 57 | 98.25 |
| scripts/tmux-agent-orchestrator.sh | 94 | 95 | 98.95 |
| scripts/agent-generator.sh | 56 | 56 | 100.00 |
| scripts/deviq-digest-append.sh | 2 | 2 | 100.00 |
| scripts/hook-wrapper.sh | 22 | 22 | 100.00 |
| scripts/lib/agent-generator-register.sh | 43 | 43 | 100.00 |
| scripts/lib/meridian-config-defaults.sh | 14 | 14 | 100.00 |
| scripts/qa-result-gate.sh | 36 | 36 | 100.00 |
| scripts/resolve-claude-dir.sh | 5 | 5 | 100.00 |
| scripts/security-filter.sh | 19 | 19 | 100.00 |
| scripts/task-contract.sh | 4 | 4 | 100.00 |
| scripts/telemetry-report.sh | 3 | 3 | 100.00 |

## Linux-only failures

The run executes 1679 tests. After the container setup below, 25 fail and 11 skip. I changed no test.

The container installs the tools that removed false failures, namely nodejs for template tests, uuid-runtime for uuidgen, ripgrep for rg, jq 1.7.1 because Debian's jq 1.6 rejects the `group` keyword as an object key, a `/private/tmp` symlink to /tmp, and a non-root user because root bypasses chmod-based not-writable tests.

### Hardcoded macOS paths

`tests/agent-generator.bats` (41 tests) and `tests/resolve-agent-settings.bats` (25 tests) call `mktemp -d /private/tmp/...` in setup. On Linux every test in both files fails with `No such file or directory`. The container mirrors the path, so these 66 tests run in this baseline. Route this to the test writer, who should use `${TMPDIR:-/tmp}` or `BATS_TEST_TMPDIR`.

### Fail on Linux because the host Claude Code executable is absent (16 tests)

| Test # | File | Test |
|---|---|---|
| 1211 | tests/self-check.bats | spawn guard allows the paired name and flips its manifest entry to running |
| 1321 | tests/team-command.bats | preflight reports agent teams enabled from project settings |
| 1324 | tests/team-command.bats | preflight is read-only and reports canonical scopes and no side effects |
| 1325 | tests/team-command.bats | preflight defaults scope to the repository root |
| 1327-1331 | tests/team-command.bats | prepare, backend records, sidecar drift, --test-dev trio, one contract per roster (5 tests) |
| 1333-1339 | tests/team-command.bats | spawn-payload, identity mismatch, record-spawn, task-payload, record-task, fail, summary (7 tests) |

The cause is that `command -v claude` finds nothing, so the host Agent enum and routing authority are unavailable (`routing authority requires an initialized .meridian or the Claude Code executable`). Test 126 already skips when Claude Code is missing. These tests should skip the same way or use a fixture executable.

### Fail on Linux for tool differences (2 tests)

| Test # | File | Test | Cause |
|---|---|---|---|
| 882 | tests/probe-map-tools.bats | lsp wins when only lsp available | resolve-lsp.sh runs a per-language binary check and the image has no language server. The test needs a fake server on PATH. |
| 1167 | tests/rtk-manager.bats | unsafe archive paths prevent installation | GNU tar strips the dir/../ prefix with a warning, so the script reports 'no executable rtk binary' instead of 'unsafe or empty paths'. bsdtar behaves differently. |

### Pass alone, fail only under kcov (7 tests)

Each passes when bats runs it without kcov in the same container. Under kcov the DEBUG trap and PS4 tracing change timing and shell variables. These are measurement artifacts, not macOS assumptions. They cost a little coverage in the files they exercise.

| Test # | File | Test |
|---|---|---|
| 111 | tests/claude-capabilities.bats | composing a catalog from host-sized candidates and records succeeds without argv overflow |
| 112 | tests/claude-capabilities.bats | composing a catalog ignores noise and blank candidate lines and keeps the matching host enum |
| 153 | tests/compile-context.bats | default configuration skips session telemetry |
| 154 | tests/compile-context.bats | project metrics opt-in records session telemetry |
| 584 | tests/meridian-routing-lock.bats | Linux and macOS select descriptor lock backends with the correct arguments |
| 585 | tests/meridian-routing-lock.bats | the real platform descriptor backend holds the guard for the owning shell lifetime (BASH_SOURCE is unbound under kcov) |
| 1425 | tests/tmux-orchestrator.bats | attached external session teardown removes only the MERIDIAN pane and runtime state |

### Already skipping on Linux (11 tests)

| Test # | Scope | Skip reason |
|---|---|---|
| 66, 1085-1090 | tests/bash32-compat.bats and 6 generator and renderer tests | /bin/bash is not bash 3.x |
| 115, 509, 623 | claude-capabilities, init and planning-boundary tests | macOS /var alias is unavailable |
| 126 | tests/claude-capabilities.bats | Claude Code is not installed |

## Scripts kcov never traced

These 42 scripts produce no kcov data. Either no test starts them under a traced `bash`, or a test runs them with a clean environment that drops the kcov hooks. Their coverage is unknown and counts as 0 for the 90 percent target.

| Directory | Scripts, without the `.sh` suffix |
| --- | --- |
| `scripts/` | agent-routing-evidence, archive-uat-guard, cache-nuke, check-claude-md-staleness, compile-debug-session-context, compile-rolling-summary, debug-skill-enrichment, delegated-workflow, extract-verified-items, indexer-sync, infer-gsd-summary, install-hooks, meridian-skills, mark-milestone-remediated, migrate-orphaned-state, persist-state-after-ship, planning-git, post-archive-hook, pre-push-hook, prepare-reverification, refresh-claude-md-meridian-sections, release-verify, rename-default-milestone, resolve-phase-state, rtk-manager, suggest-compact, validate-frontmatter, validate-summary, version-bump, write-fix-marker |
| `scripts/bootstrap/` | bootstrap-claude, bootstrap-requirements, bootstrap-roadmap |
| `scripts/bootstrap/lib/` | bootstrap-claude-migration |
| `scripts/lib/` | claude-md-meridian-sections, hook-output-guard, meridian-cache-key, meridian-config-root, phase-state-qa, team-command-transaction-run, uat-deviation-todo, uat-remediation-needs-round |

## Accepted gaps

The owner accepted these uncovered lines on 2026-11-01. No test can reach them, or kcov does not count them when a test does.

| Location | Reason |
| --- | --- |
| Each `done < <(...)` loop end in `scripts/` | kcov marks the `done` line only when a loop body runs `continue`, so a loop that finishes normally leaves it uncovered. |
| `scripts/lib/agent-generator-render.sh:30` | The `*)` branch of the word pool switch is a guard. Every caller passes pool `A` or `B`, so no input reaches it. |
| Lock backend lines in `scripts/meridian-routing.sh` | Two tests in `tests/meridian-routing-lock.bats` source the script inside `bash -c`. The script turns on `set -u`, and kcov's trace then reads the unset `BASH_SOURCE` of the `-c` frame and fails. Both tests pass outside kcov. |
| `scripts/lib/meridian-routing-validate.sh:52-53` | These two lines continue a multi-line `jq` filter. kcov counts the call on line 51 and never on its continuation lines. |
