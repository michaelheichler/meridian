#!/bin/bash
set -eu
unset CDPATH
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)
exec python3 -I -c '
import argparse
import csv
import fnmatch
import pathlib
import posixpath
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


def matches(path, filters):
    return any(path == item.rstrip("/") or path.startswith(item.rstrip("/") + "/")
               or fnmatch.fnmatchcase(path, item) for item in filters)


def excluded(path, rows):
    return any(row["scope"].startswith("exclude ") and
               matches(path, [row["from"]]) for row in rows)


def rule_pattern(row):
    if row["scope"] == "command-word":
        return r"(?<![A-Za-z0-9])" + re.escape(row["from"]) + r"(?![A-Za-z0-9])"
    if row["scope"] == "command":
        return re.escape(row["from"]) + r"(?![\w-])"
    return re.escape(row["from"])


def transform(text, kind, rows, path=""):
    protected = []

    def protect(match):
        protected.append(match.group())
        return "\x00%d\x00" % (len(protected) - 1)

    for row in rows:
        if row["scope"].startswith("preserve "):
            text = re.sub(re.escape(row["from"]), protect, text)
        if row["from"] == path and row["scope"].startswith("exclude-block "):
            markers = re.findall(r"<!-- .*? -->", row["scope"])
            if len(markers) != 2:
                raise ValueError("invalid migration block markers")
            text = re.sub(re.escape(markers[0]) + r".*?" + re.escape(markers[1]),
                          protect, text, flags=re.S)
    count = 0
    for row in rows:
        if row["kind"] == kind and row["scope"] in ("literal", "command", "command-word"):
            text, replacements = re.subn(rule_pattern(row), lambda match: row["to"], text)
            count += replacements
    text = re.sub(r"\x00(\d+)\x00", lambda match: protected[int(match[1])], text)
    return text, count


def wire_environment(text, path):
    if not path.startswith("scripts/") or path.startswith("scripts/tests/"):
        return text
    if not text.startswith("#!") or "bash" not in text.splitlines()[0]:
        return text
    if "meridian_migrate_environment" in text:
        return text
    shim = posixpath.relpath("scripts/lib/rename-migration.sh", posixpath.dirname(path))
    startup = "\n".join([
        "",
        "printf -v MERIDIAN_MIGRATION_SOURCE \"%s\" \"${BASH_SOURCE[0]}\"",
        "case \"$MERIDIAN_MIGRATION_SOURCE\" in",
        "  *\"/\"*) printf -v MERIDIAN_MIGRATION_SOURCE \"%s\" \"${MERIDIAN_MIGRATION_SOURCE%\"/\"*}\" ;;",
        "  *) printf -v MERIDIAN_MIGRATION_SOURCE \"%s\" . ;;",
        "esac",
        "if [ -f \"$MERIDIAN_MIGRATION_SOURCE/" + shim + "\" ]; then",
        "  . \"$MERIDIAN_MIGRATION_SOURCE/" + shim + "\"",
        "  meridian_migrate_environment",
        "fi",
        "unset MERIDIAN_MIGRATION_SOURCE",
        "",
    ])
    header, separator, body = text.partition("\n")
    return header + separator + startup + body


def inspect(root, rows, args):
    listing = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z",
                                      "--cached", "--others", "--exclude-standard"])
    results = []
    scanned = binary = skipped = 0
    for name in sorted(set(listing.decode().split("\0")) - {""}):
        if excluded(name, rows) or matches(name, args.exclude) or (args.include and not matches(name, args.include)):
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
        updated, contents = transform(text, "content", rows, name)
        updated = wire_environment(updated, target)
        if target != name or updated != text:
            results.append((name, int(target != name), contents, target, updated))
    return results, scanned, binary, skipped


def apply(root, results):
    targets = [row[3] for row in results]
    if len(set(targets)) != len(targets):
        raise ValueError("rename targets collide")
    for name, paths, _, target, _ in results:
        if paths and (root / target).exists():
            raise ValueError("rename target already exists, " + target)
        if pathlib.PurePosixPath(target).is_absolute() or ".." in pathlib.PurePosixPath(target).parts:
            raise ValueError("rename target escapes repository")
    for name, paths, _, target, updated in results:
        if paths:
            (root / target).parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "-C", str(root), "mv", "--", name, target], check=True)
        (root / target).write_bytes(updated.encode("utf-8"))


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--dry-run", action="store_true")
    parser.add_argument("--include", action="append", default=[])
    parser.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args(sys.argv[2:])
    root = pathlib.Path(sys.argv[1])
    if args.apply and subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all"]):
        raise ValueError("apply requires a clean working tree")
    rows = read_map(root / "scripts/dev/rename-map.tsv")
    results, scanned, binary, skipped = inspect(root, rows, args)
    if args.apply:
        apply(root, results)
    for name, paths, contents, target, _ in results:
        print("%s\tpath_renames=%d\tcontent_replacements=%d\ttarget=%s" %
              (name, paths, contents, target))
    print("SUMMARY total_files=%d affected_files=%d path_renames=%d content_replacements=%d "
          "excluded_files=%d binary_files=%d excluded_hits=0" %
          (scanned, len(results), sum(row[1] for row in results),
           sum(row[2] for row in results), skipped, binary))
    print("TOP FILES")
    for name, paths, contents, _, _ in sorted(results, key=lambda row: (-row[2], row[0]))[:10]:
        print("%s\tpath_renames=%d\tcontent_replacements=%d" % (name, paths, contents))


try:
    main()
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print("rename failed, %s" % error, file=sys.stderr)
    sys.exit(1)
' "$ROOT" "$@"
