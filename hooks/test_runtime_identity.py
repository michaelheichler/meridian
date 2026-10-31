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
    def test_symlink_to_the_runtime_dir_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat rt/decisions/secret.txt", space.root))

    def test_case_variant_of_the_runtime_dir_name_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat pl/.RUNTIME/other.txt", space.root))

    def test_hardlink_to_a_runtime_file_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat link.txt", space.root))

    def test_dotdot_path_that_lands_in_the_runtime_dir_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat ../decisions/secret.txt", space.decisions))

    def test_glob_that_matches_a_runtime_file_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat rt/decisions/sec*", space.root))

    def test_brace_step_range_that_yields_a_runtime_file_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat rt/decisions/s{00..20..10}.txt", space.root))

    def test_recursive_glob_reaches_into_hidden_directories(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat **/secret.txt", space.root))

    def test_brace_expansion_over_the_cap_is_denied(self) -> None:
        space = build_workspace(self)
        self.assertIsNotNone(bash_reason("cat rt/decisions/s{1..300}.txt", space.root))

    def test_glob_expansion_over_the_cap_is_denied(self) -> None:
        space = build_workspace(self)
        bulk = space.root / "bulk"
        bulk.mkdir()
        for number in range(BULK_FILES):
            (bulk / f"f{number}.txt").touch()
        self.assertIsNotNone(bash_reason("cat bulk/*", space.root))

    def test_unrelated_paths_and_globs_are_allowed(self) -> None:
        space = build_workspace(self)
        for command in ("cat plain.txt", "cat docs/**/x.txt", "cat docs/{a,b}.txt", "ls docs"):
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
    def test_runtime_alias_after_an_unbalanced_quote_is_denied(self) -> None:
        space = build_workspace(self)
        command = f"cat {UNPARSEABLE_QUOTE} rt/decisions/secret.txt"
        self.assertIsNotNone(bash_reason(command, space.root))

    def test_runtime_marker_in_raw_text_of_an_unparseable_command_is_denied(self) -> None:
        space = build_workspace(self)
        command = f"echo {UNPARSEABLE_QUOTE} .lbwc-planning/.runtime/x"
        self.assertIsNotNone(bash_reason(command, space.root))

    def test_module_write_after_an_unbalanced_quote_is_denied(self) -> None:
        space = build_workspace(self)
        command = f"echo {UNPARSEABLE_QUOTE} > {SOURCE}"
        self.assertIsNotNone(bash_reason(command, space.root))

    def test_harmless_unparseable_command_is_allowed(self) -> None:
        space = build_workspace(self)
        self.assertIsNone(bash_reason(f"printf {UNPARSEABLE_QUOTE}", space.root))

    def test_unparseable_command_with_a_plain_file_is_allowed(self) -> None:
        space = build_workspace(self)
        self.assertIsNone(bash_reason(f"cat {UNPARSEABLE_QUOTE} plain.txt", space.root))


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
