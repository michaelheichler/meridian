import glob
import os
import re
import sys
from typing import Any, Optional

# Because kcov keys a copy by its temp path, copies merge back by content.
LINE = re.compile(r'^\{"lineNum":"\s*(\d+)","line":"(.*?)"((?:,"class":.*)?)\},?$')
HITS = re.compile(r'"hits":"(\d+)"')
ESCAPE = re.compile(r"\\(.)")
DUMP_SUFFIX =re.compile(r"\.[0-9a-f]+\.js$")


def parse_line(raw: str) -> Optional[tuple[int, str, Optional[int]]]:
    match = LINE.match(raw.rstrip("\n"))
    if not match:
        return None
    count = HITS.search(match.group(3))
    return int(match.group(1)), ESCAPE.sub(r"\1", match.group(2)), int(count.group(1)) if count else None


def parse_dump(path: str) -> tuple[list[str], dict[int, int]]:
    with open(path, errors="replace") as handle:
        parsed = [entry for entry in map(parse_line, handle) if entry]
    source = [text for _, text, _ in parsed]
    hits = {number: count for number, _, count in parsed if count is not None}
    return source, hits


def repo_scripts(repo: str) -> dict[str, list[str]]:
    by_name: dict[str, list[str]] = {}
    for path in glob.glob(repo + "/scripts/**/*.sh", recursive=True):
        rel = os.path.relpath(path, repo)
        if not rel.startswith(("scripts/tests/", "scripts/dev/")):
            by_name.setdefault(os.path.basename(path), []).append(rel)
    return by_name


def read_lines(path: str) -> list[str]:
    with open(path, errors="replace") as handle:
        return handle.read().splitlines()


class Merger:
    def __init__(self, repo: str) -> None:
        self.repo = repo
        self.names = repo_scripts(repo)
        self.texts: dict[str, list[str]] = {}
        self.merged: dict[str, dict[int, int]] = {}

    def text(self, rel: str) -> list[str]:
        if rel not in self.texts:
            self.texts[rel] = read_lines(os.path.join(self.repo, rel))
        return self.texts[rel]

    def owner(self, name: str, source: list[str]) -> Optional[str]:
        return next((rel for rel in self.names.get(name, []) if source == self.text(rel)), None)

    def add(self, dump_path: str) -> None:
        name = DUMP_SUFFIX.sub("", os.path.basename(dump_path))
        if name not in self.names:
            return
        source, hits = parse_dump(dump_path)
        rel = self.owner(name, source)
        if rel is None:
            return
        lines = self.merged.setdefault(rel, {})
        for number, count in hits.items():
            lines[number] = lines.get(number, 0) + count


def rows(merged: dict[str, dict[int, int]]) -> list[list[Any]]:
    table = []
    for rel, lines in sorted(merged.items()):
        covered = sum(1 for count in lines.values() if count > 0)
        total = len(lines)
        table.append([rel, covered, total, "%.2f" % (100.0 if not total else 100.0 * covered / total)])
    return table


def main(report_dir: str, repo: str, out_path: str) -> None:
    merger = Merger(repo)
    for dump_path in glob.glob(report_dir + "/*.js"):
        merger.add(dump_path)
    with open(out_path, "w") as handle:
        for row in rows(merger.merged):
            handle.write("\t".join(str(cell) for cell in row) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
