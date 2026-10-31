import json
import pathlib
import sys
from typing import Dict, Iterator, List, Optional


def frontmatter_lines(path: pathlib.Path) -> Iterator[str]:
    """Yield the lines between the first two delimiters because only frontmatter carries pre_existing_issues."""
    in_frontmatter = False
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip()
        if not in_frontmatter:
            in_frontmatter = stripped == "---"
            continue
        if stripped == "---":
            return
        yield line


def parse_issue(stripped: str) -> Optional[Dict[str, str]]:
    """Return a normalized issue or None because malformed entries must not abort a sync."""
    try:
        item = json.loads(stripped[2:].strip().strip("'\""))
    except json.JSONDecodeError:
        return None
    if isinstance(item, dict) and item.get("test") and item.get("error"):
        return {"test": item["test"], "file": item.get("file") or item["test"], "error": item["error"]}
    return None


def issue_lines(path: pathlib.Path) -> Iterator[str]:
    in_issues = False
    for line in frontmatter_lines(path):
        if line.startswith("pre_existing_issues:"):
            in_issues = True
            continue
        if in_issues and line[:1].isalpha() and ":" in line:
            in_issues = False
        if in_issues and line.strip().startswith("- "):
            yield line.strip()


def extract_issues(path: pathlib.Path) -> List[Dict[str, str]]:
    parsed = (parse_issue(text) for text in issue_lines(path))
    return [issue for issue in parsed if issue]


def main(argv: List[str]) -> None:
    if argv[1] == "--glob":
        paths = list(pathlib.Path(argv[2]).glob("**/*-SUMMARY.md"))
    else:
        paths = [pathlib.Path(argv[1])]
    items: List[Dict[str, str]] = []
    for path in paths:
        items.extend(extract_issues(path))
    print(json.dumps(items))


if __name__ == "__main__":
    main(sys.argv)
