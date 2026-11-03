#!/usr/bin/env python3
import json
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CORPUS_DIR = REPO_ROOT / "references" / "deviq-corpus"


def strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def frontmatter_span(lines: list[str]) -> list[str] | None:
    if not lines or lines[0].strip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i]
    return None


def parse_inline_aliases(rest: str) -> list[str]:
    inner = rest.strip("[]")
    return [strip_quotes(x) for x in inner.split(",") if x.strip()]


def parse_block_aliases(fm_lines: list[str], start: int) -> tuple[list[str], int]:
    items = []
    j = start
    while j < len(fm_lines) and fm_lines[j].strip().startswith("-"):
        items.append(strip_quotes(fm_lines[j].strip()[1:]))
        j += 1
    return items, j


@dataclass
class FrontmatterParser:
    lines: list[str]
    result: dict[str, str | list[str]]

    def apply_key(self, index: int) -> int:
        key, _, rest = self.lines[index].partition(":")
        key, rest = key.strip(), rest.strip()
        if key in ("title", "description"):
            self.result[key] = strip_quotes(rest)
            return index
        if key != "aliases":
            return index
        if rest.startswith("["):
            self.result["aliases"] = parse_inline_aliases(rest)
            return index
        self.result["aliases"], next_index = parse_block_aliases(self.lines, index + 1)
        return next_index - 1


def parse_frontmatter(text: str) -> dict[str, str | list[str]]:
    result: dict[str, str | list[str]] = {"title": "", "description": "", "aliases": []}
    fm_lines = frontmatter_span(text.splitlines())
    if fm_lines is None:
        return result

    parser = FrontmatterParser(fm_lines, result)
    i = 0
    while i < len(fm_lines):
        line = fm_lines[i]
        if line.strip() and not line.startswith((" ", "\t")) and ":" in line:
            i = parser.apply_key(i)
        i += 1
    return result


def build_index() -> list[dict[str, str | list[str]]]:
    entries = []
    for md_path in sorted(CORPUS_DIR.glob("*/*.md")):
        category = md_path.parent.name
        slug = md_path.stem
        text = md_path.read_text(encoding="utf-8", errors="ignore")
        frontmatter = parse_frontmatter(text)
        entries.append({
            "id": f"{category}/{slug}",
            "category": category,
            "title": frontmatter["title"],
            "description": frontmatter["description"],
            "aliases": frontmatter["aliases"],
        })
    entries.sort(key=lambda e: e["id"])
    return entries


def main() -> int:
    if not CORPUS_DIR.is_dir():
        print(f"deviq-index: corpus dir not found: {CORPUS_DIR}", file=sys.stderr)
        return 1
    entries = build_index()
    out_path = CORPUS_DIR / "index.json"
    out_path.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
    print(f"deviq-index: wrote {len(entries)} entries to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
