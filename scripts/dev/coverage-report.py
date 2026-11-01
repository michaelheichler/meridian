import json
import sys
from typing import Any


def percent(covered: int, total: int) -> float:
    return 100.0 if not total else 100.0 * covered / total


def file_row(path: str, data: dict[str, Any]) -> list[Any]:
    summary = data["summary"]
    branches = summary.get("num_branches", 0)
    covered_branches = summary.get("covered_branches", 0)
    return [
        path,
        summary["covered_lines"],
        summary["num_statements"],
        "%.2f" % percent(summary["covered_lines"], summary["num_statements"]),
        covered_branches,
        branches,
        "%.2f" % percent(covered_branches, branches),
    ]


def branch_rows(path: str, data: dict[str, Any], source_lines: list[str]) -> list[list[Any]]:
    rows = []
    for covered, key in ((1, "executed_branches"), (0, "missing_branches")):
        for origin, target in data.get(key, []):
            text = source_lines[origin - 1].strip() if 0 < origin <= len(source_lines) else ""
            rows.append([path, origin, target, covered, text])
    return sorted(rows, key=lambda row: (row[1], row[2]))


def read_lines(path: str) -> list[str]:
    try:
        with open(path) as handle:
            return handle.read().splitlines()
    except OSError:
        return []


def write_tsv(path: str, rows: list[list[Any]]) -> None:
    with open(path, "w") as handle:
        for row in rows:
            handle.write("\t".join(str(cell) for cell in row) + "\n")


def main(report_path: str, out_dir: str) -> None:
    with open(report_path) as handle:
        report = json.load(handle)
    files, branches = [], []
    for path, data in sorted(report["files"].items()):
        files.append(file_row(path, data))
        branches.extend(branch_rows(path, data, read_lines(path)))
    write_tsv(out_dir + "/python-files.tsv", files)
    write_tsv(out_dir + "/python-branches.tsv", branches)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
