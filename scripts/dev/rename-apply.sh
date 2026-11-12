#!/bin/bash
set -eu
unset CDPATH

if [ "$#" -ne 1 ] || [ "$1" != --dry-run ]; then
  printf '%s\n' 'Usage: rename-apply.sh --dry-run' >&2
  exit 2
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)
exec python3 -I -c '
import csv
import pathlib
import re
import subprocess
import sys


def read_map(path):
    with path.open(newline="") as source:
        rows = list(csv.DictReader(source, delimiter="\t"))
    if not rows or set(rows[0]) != {"kind", "from", "to", "scope"}:
        raise ValueError("invalid rename map header")
    for row in rows:
        if row["kind"] not in ("path", "content") or not row["from"]:
            raise ValueError("invalid rename map row")
    return rows


def excluded(path, rows):
    return any(row["scope"].startswith("exclude ") and
               (path == row["from"] or path.startswith(row["from"] + "/"))
               for row in rows)


def rule_pattern(row):
    if row["scope"] == "command-word":
        return r"(?<![A-Za-z0-9])" + re.escape(row["from"]) + r"(?![A-Za-z0-9])"
    if row["scope"] == "command":
        return re.escape(row["from"]) + r"(?![\w-])"
    return re.escape(row["from"])


def transform(text, kind, rows):
    rules = [row for row in rows if row["kind"] == kind and
             row["scope"] in ("literal", "command", "command-word")]
    choices = [(len(row["from"]), rule_pattern(row), row["to"], True)
               for row in rules]
    choices += [(len(row["from"]), re.escape(row["from"]), row["to"], False)
                for row in rows if row["scope"].startswith("preserve ")]
    choices.sort(key=lambda choice: -choice[0])
    pattern = re.compile("|".join("(?P<r%d>%s)" % (index, choice[1])
                                  for index, choice in enumerate(choices)))
    count = 0

    def replace(match):
        nonlocal count
        choice = choices[int(match.lastgroup[1:])]
        count += int(choice[3])
        return choice[2]

    return pattern.sub(replace, text), count


def content_count(text, path, rows):
    blocks = [row for row in rows if row["from"] == path and
              row["scope"].startswith("exclude-block ")]
    for row in blocks:
        markers = re.findall(r"<!-- .*? -->", row["scope"])
        if len(markers) != 2:
            raise ValueError("invalid migration block markers")
        text = re.sub(re.escape(markers[0]) + r".*?" + re.escape(markers[1]),
                      "", text, flags=re.S)
    return transform(text, "content", rows)[1]


def inspect(root, rows):
    listing = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z",
                                      "--cached", "--others", "--exclude-standard"])
    results = []
    scanned = binary = skipped = 0
    for name in sorted(set(listing.decode().split("\0")) - {""}):
        if excluded(name, rows):
            skipped += 1
            continue
        path = root / name
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data:
            binary += 1
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            binary += 1
            continue
        scanned += 1
        target, _ = transform(name, "path", rows)
        paths = int(target != name)
        contents = content_count(text, name, rows)
        if paths or contents:
            results.append((name, paths, contents, target))
    return results, scanned, binary, skipped


def main():
    root = pathlib.Path(sys.argv[1])
    rows = read_map(root / "scripts/dev/rename-map.tsv")
    results, scanned, binary, skipped = inspect(root, rows)
    for name, paths, contents, target in results:
        print("%s\tpath_renames=%d\tcontent_replacements=%d\ttarget=%s" %
              (name, paths, contents, target))
    print("SUMMARY total_files=%d affected_files=%d path_renames=%d content_replacements=%d "
          "excluded_files=%d binary_files=%d excluded_hits=0" %
          (scanned, len(results), sum(row[1] for row in results),
           sum(row[2] for row in results), skipped, binary))
    print("TOP FILES")
    for name, paths, contents, _ in sorted(results, key=lambda row: (-row[2], row[0]))[:10]:
        print("%s\tpath_renames=%d\tcontent_replacements=%d" % (name, paths, contents))


try:
    main()
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print("rename dry run failed: %s" % error, file=sys.stderr)
    sys.exit(1)
' "$ROOT"
