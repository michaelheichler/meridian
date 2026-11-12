import unittest
from collections import Counter
from pathlib import Path
from unittest.mock import patch

from hooks.hook_batch import BashBatch
from hooks.dispatch_fixtures import DispatchProject, decision, warnings
from hooks.dispatch_scenarios import AGGREGATION_CASES, aggregation_case, batching_case, policy_case

PRE_ROUTES = {
    "AskUserQuestion": ("user_question_guard",),
    "Agent": ("user_question_guard", "agent-spawn-guard.sh"),
    "Task": ("agent-spawn-guard.sh",),
    "TaskCreate": ("user_question_guard", "agent-spawn-guard.sh"),
    "TaskUpdate": ("user_question_guard",),
    "Write": ("user_question_guard", "skill_gate", "scope_guard", "file-guard.sh", "security-filter.sh"),
    "Edit": ("user_question_guard", "skill_gate", "scope_guard", "file-guard.sh", "security-filter.sh"),
    "NotebookEdit": ("user_question_guard", "skill_gate", "scope_guard", "file-guard.sh"),
    "Bash": ("user_question_guard", "bash-guard.sh"),
    "Skill": ("user_question_guard",),
    "SendMessage": ("user_question_guard", "message_scope_guard"),
    "Grep": ("user_question_guard", "security-filter.sh"),
    "Glob": ("user_question_guard", "skill_gate", "security-filter.sh"),
    "Workflow": ("workflow-spawn-guard.sh",),
    "Read": ("skill_gate", "security-filter.sh"),
}
POST_ROUTES = {
    "AskUserQuestion": ("user_question_guard",),
    "Bash": ("validate-commit.sh", "context_usage"),
    "Write": ("context_usage", "validate-summary.sh", "validate-frontmatter.sh", "state-updater.sh", "deviq-nudge.sh"),
    "Edit": ("context_usage", "validate-summary.sh", "validate-frontmatter.sh", "state-updater.sh", "deviq-nudge.sh"),
}

GUARD_MODULES = (
    "hooks/scope_guard.py", "hooks/skill_gate.py", "hooks/message_scope_guard.py", "hooks/tmux_git_policy.py",
    "hooks/tmux_restrictions.py", "hooks/context_usage.py", "hooks/rename_migration.py", "hooks/debug_logging.py",
)
PACKAGE_GUARD = Path("/package/scripts/bash-guard.sh")
EXPLICIT_GUARD = Path("/explicit/scripts/bash-guard.sh")
PLANTED_GUARD = Path("/tmp/.meridian-plugin-root-link-planted/scripts/bash-guard.sh")
RESOLUTION_ROWS = (
    ({}, {PACKAGE_GUARD, PLANTED_GUARD}, PACKAGE_GUARD),
    ({"CLAUDE_PLUGIN_ROOT": "/explicit"}, {EXPLICIT_GUARD, PACKAGE_GUARD, PLANTED_GUARD}, EXPLICIT_GUARD),
    ({"CLAUDE_PLUGIN_ROOT": "/explicit"}, {PACKAGE_GUARD, PLANTED_GUARD}, PACKAGE_GUARD),
    ({}, {PLANTED_GUARD}, None),
)


# Because the public run path launches bash, resolution runs alone.
def resolved_guard(environment: dict, existing: set) -> "Path | None":
    batch = object.__new__(BashBatch)
    batch.scripts = PACKAGE_GUARD.parent
    with patch.dict("os.environ", environment, clear=True), patch("glob.glob", return_value=[str(PLANTED_GUARD)]):
        with patch.object(Path, "is_file", lambda path: path in existing):
            return batch._target(PACKAGE_GUARD.name)


def malformed_rows() -> list:
    return ["{", "[]", {}, {"hook_event_name": "PreToolUse"}] + [
        {"hook_event_name": event, "tool_name": tool}
        for event, tool in (("PreToolUse", None), ("PreToolUse", {}), ("PreToolUse", 7), ("PreToolUse", ""))]


class DispatcherTest(unittest.TestCase):
    def test_guard_failures_allow_only_the_matching_tools_and_preserve_explicit_denials(self) -> None:
        routes = [(event, tool, guards) for event, table in (("PreToolUse", PRE_ROUTES), ("PostToolUse", POST_ROUTES))
                  for tool, guards in table.items()]
        for event, tool, guards in routes:
            with self.subTest(event=event, tool=tool):
                space = DispatchProject(self)
                space.crash_all()
                result = space.run({**space.event(tool), "hook_event_name": event}, event)
                self.assertEqual((result.returncode, result.stdout), (0, ""))
                self.assertEqual([line.split("warning: ")[1].split(" exited")[0] for line in warnings(result)], list(guards))
        for data in malformed_rows():
            with self.subTest(routing=data):
                space = DispatchProject(self)
                result = space.run(data)
                self.assertEqual((result.returncode, result.stdout), (0, ""))
                self.assertEqual(len(warnings(result)), 1)
        for kind in AGGREGATION_CASES:
            with self.subTest(aggregation=kind):
                space = DispatchProject(self)
                space.neutralize()
                result, actual, expected = aggregation_case(space, kind)
                self.assertEqual(actual, expected)
        for environment, existing, expected in RESOLUTION_ROWS:
            with self.subTest(resolution=environment, files=existing):
                self.assertEqual(resolved_guard(environment, existing), expected)

    def test_registered_guards_keep_policy_and_decision_lifecycle(self) -> None:
        rows = ["engineer-message", "required-reading", "answer", "stale-answer"]
        rows += ["pending-" + tool for tool in ("Agent", "TaskCreate", "TaskUpdate", "Skill", "SendMessage", "Write", "Edit", "NotebookEdit", "Bash")]
        rows += ["protected-" + path for path in ("hooks/dispatch.py", "hooks/hook_batch.py", "hooks/hook_output.py", "scripts/hook-batch.sh") + GUARD_MODULES]
        for row in rows:
            with self.subTest(policy=row):
                space = DispatchProject(self)
                result, expected, state = policy_case(space, row)
                self.assertEqual((decision(result), state), (expected, {"answer": "resolved", "stale-answer": "cancelled"}.get(row)))
                self.assertEqual(result.returncode, 0)
                self.assertEqual(warnings(result), [])
        for path in GUARD_MODULES:
            with self.subTest(shell_write=path):
                space = DispatchProject(self)
                result = space.run(space.event("Bash", {"command": "printf x > " + path}))
                self.assertEqual(decision(result), "deny")
                self.assertEqual(result.returncode, 0)
                self.assertEqual(warnings(result), [])
        for path in GUARD_MODULES:
            with self.subTest(shell_write=path):
                space = DispatchProject(self)
                result = space.run(space.event("Bash", {"command": "printf x > " + path}))
                self.assertEqual((decision(result), result.returncode, warnings(result)), ("deny", 0, []))

    def test_batched_json_reads_preserve_file_scope_and_nudge_cooldown(self) -> None:
        rows = [("file", path) for path in ("src/app.py", "src/app.py\n", "src/tab\tname.py", "src/line\nbreak.py", "", "src/other.py")]
        rows += [("manifest", path) for path in ("src/from-newline.py", "src/from-tab\tname.py", "src/other.py")]
        rows += [("contract", path) for path in ("src/app.py", "src/tab\tname.py", "src/other.py")]
        rows += [("nudge", content) for content in ("duplicate code", "unrelated content", "", "cooldown")]
        for kind, value in rows:
            with self.subTest(kind=kind, value=value):
                space = DispatchProject(self)
                space.neutralize()
                actual, expected, result, budget = batching_case(space, kind, value)
                self.assertEqual(actual, expected)
                self.assertLessEqual(space.jq_calls(), budget)
                self.assertLessEqual(max(Counter(space.jq_sources()).values(), default=0), 1)
                self.assertEqual(warnings(result), [])


if __name__ == "__main__":
    unittest.main()
