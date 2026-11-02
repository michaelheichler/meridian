import unittest

from hooks.brace_expansion import ExpansionTooComplex, expand_braces
from hooks.guard_fixtures import (
    HOOKS_DIR,
    PROTECTED_STEMS,
    bash_reason,
    build_workspace,
    tool_reason,
)
from hooks.path_identity import TooManyMatches, expand_glob

DIR = str(HOOKS_DIR)
BRACE_CAP = 256
GLOB_CAP = 1024

BRACE_FORMS = (
    ("plain", ["plain"]),
    ("a{b,c}d", ["abd", "acd"]),
    ("a{,b}", ["a", "ab"]),
    ("x{a,b{1,2}}", ["xa", "xb1", "xb2"]),
    ("f{1..3}", ["f1", "f2", "f3"]),
    ("f{3..1}", ["f3", "f2", "f1"]),
    ("f{5..1..2}", ["f5", "f3", "f1"]),
    ("f{00..10..5}", ["f00", "f05", "f10"]),
    ("f{a..c}", ["fa", "fb", "fc"]),
    ("{single}", ["{single}"]),
)

GLOBBED_MODULE_WRITES = (
    f"rm {DIR}/guard_p*.py",
    f"rm {DIR}/**/guard_pa*s.py",
    f"echo x > {DIR}/g?ard_paths.py",
    f"cp new {DIR}/guard_pat[h]s.py",
    f"chmod 777 {DIR}/decision_c*.py",
)

BRACED_MODULE_WRITES = (
    f"mv new {DIR}/guard_{{paths,tmp}}.py",
    f"chmod 777 {DIR}/{{read_only_command,tmp}}.py",
    f"rm {DIR}/brace_expansion.p{{x..z}}",
    f"python3 {DIR}/decision_{{common,tmp}}.py",
    f"source {DIR}/path_{{identity,tmp}}.py",
)


class BraceExpansionTest(unittest.TestCase):
    def test_brace_forms_expand_the_way_a_shell_expands_them(self) -> None:
        for word, expected in BRACE_FORMS:
            with self.subTest(word=word):
                self.assertEqual(expand_braces(word), expected)

    def test_a_range_of_exactly_the_cap_expands(self) -> None:
        self.assertEqual(len(expand_braces(f"f{{1..{BRACE_CAP}}}")), BRACE_CAP)

    def test_expansions_that_exceed_the_budget_are_rejected(self) -> None:
        for word in (f"f{{1..{BRACE_CAP + 1}}}", "{1..20}{1..20}"):
            with self.subTest(word=word), self.assertRaises(ExpansionTooComplex):
                expand_braces(word)


class GlobExpansionTest(unittest.TestCase):
    def test_double_star_finds_files_below_hidden_directories(self) -> None:
        space = build_workspace(self)
        hidden = space.root / "docs" / ".hid"
        hidden.mkdir()
        (hidden / "f.txt").touch()
        self.assertIn(str(hidden / "f.txt"), expand_glob(f"{space.root}/**/f.txt"))

    def test_glob_with_exactly_the_cap_of_matches_expands(self) -> None:
        space = build_workspace(self)
        for number in range(GLOB_CAP):
            (space.root / "docs" / f"f{number}.txt").touch()
        self.assertEqual(len(expand_glob(f"{space.root}/docs/f*.txt")), GLOB_CAP)

    def test_glob_one_past_the_cap_is_rejected(self) -> None:
        space = build_workspace(self)
        for number in range(GLOB_CAP + 1):
            (space.root / "docs" / f"f{number}.txt").touch()
        with self.assertRaises(TooManyMatches):
            expand_glob(f"{space.root}/docs/f*.txt")


class ModuleWriteProtectionTest(unittest.TestCase):
    def test_expanded_module_write_operands_are_denied(self) -> None:
        space = build_workspace(self)
        for command in (*GLOBBED_MODULE_WRITES, *BRACED_MODULE_WRITES):
            with self.subTest(command=command):
                self.assertIsNotNone(bash_reason(command, space.root))

    def test_every_guard_module_is_protected_from_deletion(self) -> None:
        space = build_workspace(self)
        for stem in PROTECTED_STEMS:
            with self.subTest(stem=stem):
                self.assertIsNotNone(bash_reason(f"rm {DIR}/{stem}.py", space.root))

    def test_file_tools_cannot_write_a_guard_module(self) -> None:
        space = build_workspace(self)
        for tool in ("Write", "Edit"):
            with self.subTest(tool=tool):
                tool_input = {"file_path": f"{DIR}/{PROTECTED_STEMS[-1]}.py", "content": "x"}
                self.assertIsNotNone(tool_reason(tool, tool_input, space.root))

    def test_brace_and_glob_forms_that_miss_the_guard_modules_are_allowed(self) -> None:
        space = build_workspace(self)
        for command in (f"rm {DIR}/guard_{{other,tmp}}.py", f"rm {DIR}/zz_*.py"):
            with self.subTest(command=command):
                self.assertIsNone(bash_reason(command, space.root))


if __name__ == "__main__":
    unittest.main()
