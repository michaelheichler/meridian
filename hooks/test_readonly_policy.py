import os
import unittest

from hooks.guard_fixtures import GUARD_PATHS_STEM, bash_reason, build_workspace, module_path

SOURCE = module_path(GUARD_PATHS_STEM)

ALLOWED_READS = (
    f"cat -n {SOURCE}",
    f"cat -vet {SOURCE}",
    f"head -n 5 {SOURCE}",
    f"head -5 {SOURCE}",
    f"tail -n +5 {SOURCE}",
    f"wc -l {SOURCE}",
    f"ls -lah {SOURCE}",
    f"stat -L {SOURCE}",
    f"grep -n -i -e foo {SOURCE}",
    f"grep -A2 -m 3 --color=never foo {SOURCE}",
    f"grep -rn foo {SOURCE}",
    f"grep -R foo {SOURCE}",
    "grep -rn x hooks/*.py",
    f"rg -n x {SOURCE}",
    "rg -n x hooks/*.py",
    f"find {SOURCE} -name {GUARD_PATHS_STEM}.py",
    f"find hooks -name {GUARD_PATHS_STEM}.py",
    f"sed -n 1,5p {SOURCE}",
    f"cat {SOURCE} | sort -nr -k2 | uniq -c | cut -d, -f1",
    f"cat {SOURCE} | grep -v foo | wc -l",
)

DENIED_SOURCE_ACCESS = (
    f"tail -f {SOURCE}",
    f"tail -F {SOURCE}",
    f"tail --follow {SOURCE}",
    f"head -z {SOURCE}",
    f"cat --show-all {SOURCE}",
    f"ls -R {SOURCE}",
    f"find {SOURCE} -exec cat {SOURCE} +",
    f"find {SOURCE} -delete",
    f"find {SOURCE} -fprint out",
    f"rg --pre cat x {SOURCE}",
    "grep -rn x hooks/*.py",
    "rg x hooks/*.py",
    "grep -rn x .meridian/.runtime",
    "grep -rn x .meridian/.runtime/decisions/secret.txt",
    "grep x .meridian/.runtime/decisions/*.txt",
    "rg x .meridian/.runtime/decisions/*.txt",
    f"grep x {SOURCE} .meridian/.runtime/decisions/*.txt",
    f"grep -rn x {SOURCE}; true",
    f"grep -rn x {SOURCE} && true",
    f"grep -rn x {SOURCE} | wc -l",
    f"grep -rn x {SOURCE} $(true)",
    f"grep -rn x {SOURCE} > out",
    f"grep -f patterns {SOURCE}",
    f"grep -d recurse foo {SOURCE}",
    f"grep --include=x foo {SOURCE}",
    f"grep --exclude-dir=x foo {SOURCE}",
    f"sed -i s/a/b/ {SOURCE}",
    f"sed -n w=out {SOURCE}",
    f"cat {SOURCE} | sed -n 1p",
    f"cat {SOURCE} | sort -o out",
    f"cat {SOURCE} | uniq out",
    f"cat {SOURCE} | tee out",
    f"cat {SOURCE} > out",
    f"cat {SOURCE}; true",
    f"cat {SOURCE} && true",
    f"cp {SOURCE} out",
    f"awk 1 {SOURCE}",
)

DROPPED_EXEMPTION_TOKENS = ("$X", "`x`", "*", "?", "[a]", "{a,b}", "~", "é", "$(true)")

FILES0_DENIED = (
    "cat plain.txt | sort --files0-from=list0",
    "cat plain.txt | sort --files0-from list0",
    "cat plain.txt | sort --files0=list0",
    "sort --fil list0",
    "sort --files=list0",
    "wc --files0-from=list0",
    "wc --files0 list0",
    "wc --f=list0",
    "cat --files0-from=list0",
)

FILES0_LOOKALIKES = ("rm --force plain.txt", "rg --files", "cat --number plain.txt")


class SourceReadAllowlistTest(unittest.TestCase):
    def test_plain_read_forms_of_a_guard_source_file_are_allowed(self) -> None:
        space = build_workspace(self)
        sources = space.root / "hooks"
        sources.mkdir()
        os.link(SOURCE, sources / f"{GUARD_PATHS_STEM}.py")
        for command in (*ALLOWED_READS, "cat -n plain.txt"):
            with self.subTest(command=command):
                self.assertIsNone(bash_reason(command, space.root))

    def test_flags_and_shapes_outside_the_allowlist_are_denied(self) -> None:
        space = build_workspace(self)
        sources = space.root / "hooks"
        sources.mkdir()
        (sources / f"{GUARD_PATHS_STEM}.py").symlink_to(SOURCE)
        for command in (*DENIED_SOURCE_ACCESS, f"cat -n {SOURCE} link.txt"):
            with self.subTest(command=command):
                self.assertIsNotNone(bash_reason(command, space.root))

    def test_one_expansion_token_drops_the_read_exemption(self) -> None:
        space = build_workspace(self)
        for token in DROPPED_EXEMPTION_TOKENS:
            with self.subTest(token=token):
                self.assertIsNotNone(bash_reason(f"cat -n {SOURCE} {token}", space.root))


class Files0OptionTest(unittest.TestCase):
    def test_files0_from_and_its_abbreviations_are_denied(self) -> None:
        space = build_workspace(self)
        for command in FILES0_DENIED:
            with self.subTest(command=command):
                self.assertIsNotNone(bash_reason(command, space.root))

    def test_options_that_only_resemble_files0_are_allowed(self) -> None:
        space = build_workspace(self)
        for command in FILES0_LOOKALIKES:
            with self.subTest(command=command):
                self.assertIsNone(bash_reason(command, space.root))


if __name__ == "__main__":
    unittest.main()
