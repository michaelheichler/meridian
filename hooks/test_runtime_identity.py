import unittest

from hooks.guard_fixtures import (
    GUARD_PATHS_STEM,
    bash_reason,
    build_workspace,
    module_path,
    tool_reason,
)

SOURCE = module_path(GUARD_PATHS_STEM)
UNPARSEABLE_QUOTE = "$'a\\'b'"
BULK_FILES = 1100


class RuntimeAliasTest(unittest.TestCase):
    def test_resolved_runtime_operands_are_denied(self) -> None:
        space = build_workspace(self)
        rows = (
            ("cat rt/decisions/secret.txt", space.root),
            ("cat pl/.RUNTIME/other.txt", space.root),
            ("cat link.txt", space.root),
            ("cat ../decisions/secret.txt", space.decisions),
            ("cat rt/decisions/sec*", space.root),
            ("cat rt/decisions/s{00..20..10}.txt", space.root),
            ("cat **/secret.txt", space.root),
        )
        for command, cwd in rows:
            with self.subTest(command=command, cwd=cwd):
                self.assertIsNotNone(bash_reason(command, cwd))

    def test_operand_expansion_over_budget_fails_closed(self) -> None:
        space = build_workspace(self)
        bulk = space.root / "bulk"
        bulk.mkdir()
        for number in range(BULK_FILES):
            (bulk / f"f{number}.txt").touch()
        for command in ("cat bulk/*", "cat rt/decisions/s{1..300}.txt"):
            with self.subTest(command=command):
                self.assertIsNotNone(bash_reason(command, space.root))

    def test_unrelated_paths_and_globs_are_allowed(self) -> None:
        space = build_workspace(self)
        for command in ("cat plain.txt", "cat docs/**/x.txt", "cat docs/{a,b}.txt", "ls docs", "echo $SAFE", "echo `true`"):
            with self.subTest(command=command):
                self.assertIsNone(bash_reason(command, space.root))

    def test_every_tool_is_denied_a_runtime_path(self) -> None:
        space = build_workspace(self)
        attempts = (
            ("Read", {"file_path": "rt/decisions/secret.txt"}),
            ("Write", {"file_path": "rt/decisions/new.txt", "content": "x"}),
            ("Edit", {"file_path": "link.txt", "old_string": "S", "new_string": "T"}),
            ("NotebookEdit", {"notebook_path": "rt/decisions/n.ipynb"}),
            ("Bash", {"command": "echo x > rt/decisions/new.txt"}),
            ("Bash", {"command": "rm -rf rt"}),
            ("Bash", {"command": "find rt -name secret.txt"}),
        )
        for tool, tool_input in attempts:
            with self.subTest(tool=tool, tool_input=tool_input):
                self.assertIsNotNone(tool_reason(tool, tool_input, space.root))


class UnparseableCommandTest(unittest.TestCase):
    def test_unparseable_commands_still_deny_protected_operands(self) -> None:
        space = build_workspace(self)
        rows = (
            f"cat {UNPARSEABLE_QUOTE} rt/decisions/secret.txt",
            f"echo {UNPARSEABLE_QUOTE} .lbwc-planning/.runtime/x",
            f"echo {UNPARSEABLE_QUOTE} > {SOURCE}",
        )
        for command in rows:
            with self.subTest(command=command):
                self.assertIsNotNone(bash_reason(command, space.root))

    def test_unparseable_commands_without_protected_operands_are_allowed(self) -> None:
        space = build_workspace(self)
        for command in (f"printf {UNPARSEABLE_QUOTE}", f"cat {UNPARSEABLE_QUOTE} plain.txt"):
            with self.subTest(command=command):
                self.assertIsNone(bash_reason(command, space.root))


class SearchToolScopeTest(unittest.TestCase):
    def test_grep_and_glob_scopes_that_reach_the_runtime_dir_are_denied(self) -> None:
        space = build_workspace(self)
        runtime = str(space.planning / ".runtime")
        attempts = (
            ("Grep", {"pattern": "S", "path": "rt"}),
            ("Grep", {"pattern": "S", "path": "rt/decisions"}),
            ("Grep", {"pattern": "S", "path": runtime}),
            ("Glob", {"pattern": "**/secret.txt", "path": "rt"}),
            ("Glob", {"pattern": "rt/**"}),
            ("Glob", {"pattern": ".lbwc-planning/.runtime/**"}),
            ("Glob", {"pattern": "*.txt"}),
        )
        for tool, tool_input in attempts:
            with self.subTest(tool=tool, tool_input=tool_input):
                self.assertIsNotNone(tool_reason(tool, tool_input, space.root))

    def test_grep_and_glob_scopes_away_from_the_runtime_dir_are_allowed(self) -> None:
        space = build_workspace(self)
        attempts = (
            ("Grep", {"pattern": "p", "path": "plain.txt"}),
            ("Grep", {"pattern": "p", "path": "docs"}),
            ("Grep", {"pattern": "def", "path": SOURCE}),
            ("Glob", {"pattern": "plain.*"}),
        )
        for tool, tool_input in attempts:
            with self.subTest(tool=tool, tool_input=tool_input):
                self.assertIsNone(tool_reason(tool, tool_input, space.root))


if __name__ == "__main__":
    unittest.main()
