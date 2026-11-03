#!/usr/bin/env python3
from __future__ import annotations

import argparse
from contextlib import contextmanager, suppress
import json
import os
import stat
import sys
from typing import Iterator, Optional
import uuid


Location = tuple[int, str]
LocationPair = tuple[Location, Location]
DescriptorPair = tuple[Optional[int], Optional[int]]
PathPair = tuple[str, str]


def fail(message: str) -> None:
    raise RuntimeError(message)


@contextmanager
def held_fd(fd: int | None) -> Iterator[int | None]:
    try:
        yield fd
    finally:
        if fd is not None:
            os.close(fd)


@contextmanager
def held_pair(descriptors: DescriptorPair) -> Iterator[None]:
    try:
        yield
    finally:
        source_fd, destination_fd = descriptors
        if source_fd is not None:
            os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)


def private_directory(fd: int, path: str) -> None:
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        fail(f"not a directory: {path}")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        fail(f"not a private directory: {path}")


def private_file(fd: int, path: str) -> None:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        fail(f"not a regular file: {path}")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        fail(f"not a private file: {path}")


def open_root(root: str) -> int:
    return os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def components(relative: str) -> list[str]:
    parts = relative.split("/")
    if not relative or any(part in {"", ".", ".."} for part in parts):
        fail(f"unsafe relative path: {relative}")
    return parts


def open_child(parent_fd: int, name: str, create: bool) -> int:
    try:
        return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except FileNotFoundError:
        if not create:
            raise
    os.mkdir(name, 0o700, dir_fd=parent_fd)
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


def open_parent(root_fd: int, relative: str, create: bool) -> Location:
    parts = components(relative)
    current = os.dup(root_fd)
    try:
        private_directory(current, "root")
        for part in parts[:-1]:
            next_fd = open_child(current, part, create)
            private_directory(next_fd, part)
            os.close(current)
            current = next_fd
        return current, parts[-1]
    except Exception:
        os.close(current)
        raise


@contextmanager
def parent_location(root: str, relative: str, create: bool) -> Iterator[Location]:
    with held_fd(open_root(root)) as root_fd:
        parent_fd, name = open_parent(root_fd, relative, create)
        with held_fd(parent_fd):
            yield parent_fd, name


@contextmanager
def parent_pair(root_fd: int, source: str, destination: str) -> Iterator[LocationPair]:
    source_parent, source_name = open_parent(root_fd, source, False)
    destination_parent, destination_name = open_parent(root_fd, destination, False)
    with held_pair((source_parent, destination_parent)):
        yield (source_parent, source_name), (destination_parent, destination_name)


def open_optional(location: Location) -> int | None:
    parent_fd, name = location
    try:
        return os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except FileNotFoundError:
        return None


def validate_named_file(location: Location, relative: str) -> None:
    parent_fd, name = location
    with held_fd(os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)) as fd:
        private_file(fd, relative)


def write_temporary(location: Location, document: str) -> None:
    parent_fd, temporary = location
    temp_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent_fd)
    with held_fd(temp_fd):
        os.write(temp_fd, (document + "\n").encode())
        os.fsync(temp_fd)
        private_file(temp_fd, temporary)


def replace_json(location: Location, relative: str, document: str) -> None:
    parent_fd, name = location
    private_directory(parent_fd, relative)
    temporary = f".{name}.{uuid.uuid4().hex}.tmp"
    write_temporary((parent_fd, temporary), document)
    with held_fd(open_optional(location)) as existing:
        if existing is not None:
            private_file(existing, relative)
    os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    validate_named_file(location, relative)
    os.fsync(parent_fd)


def write_json(root: str, relative: str, document: str) -> None:
    json.loads(document)
    with parent_location(root, relative, True) as location:
        replace_json(location, relative, document)


def populate_owner(location: Location, owner: str) -> None:
    parent_fd, temporary = location
    os.mkdir(temporary, 0o700, dir_fd=parent_fd)
    temp_fd = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    with held_fd(temp_fd):
        private_directory(temp_fd, temporary)
        owner_fd = os.open("owner.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=temp_fd)
        with held_fd(owner_fd):
            os.write(owner_fd, (owner + "\n").encode())
            os.fsync(owner_fd)
        os.fsync(temp_fd)


def cleanup_owner(location: Location) -> None:
    parent_fd, temporary = location
    with suppress(Exception):
        cleanup_fd = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        with held_fd(cleanup_fd):
            os.unlink("owner.json", dir_fd=cleanup_fd)
    with suppress(Exception):
        os.rmdir(temporary, dir_fd=parent_fd)


def rename_directory(location: Location, name: str) -> None:
    parent_fd, temporary = location
    try:
        os.rename(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    except OSError as error:
        if error.errno in {17, 66}:
            raise FileExistsError(name) from error
        raise
    os.fsync(parent_fd)


def publish_owner(location: Location, relative: str, owner: str) -> None:
    parent_fd, name = location
    private_directory(parent_fd, relative)
    staging = parent_fd, f".{name}.{uuid.uuid4().hex}.tmp"
    try:
        populate_owner(staging, owner)
        rename_directory(staging, name)
    except Exception:
        cleanup_owner(staging)
        raise


def publish_directory(root: str, relative: str, owner: str) -> None:
    json.loads(owner)
    with parent_location(root, relative, True) as location:
        publish_owner(location, relative, owner)


def move_file(source: Location, destination: Location, relative: str) -> None:
    source_parent, source_name = source
    destination_parent, destination_name = destination
    try:
        os.link(source_name, destination_name, src_dir_fd=source_parent, dst_dir_fd=destination_parent, follow_symlinks=False)
    except FileExistsError:
        fail(f"destination already exists: {relative}")
    os.unlink(source_name, dir_fd=source_parent)
    os.fsync(source_parent)
    if source_parent != destination_parent:
        os.fsync(destination_parent)


def move(root: str, source: str, destination: str) -> None:
    with held_fd(open_root(root)) as root_fd, parent_pair(root_fd, source, destination) as locations:
        source_location, destination_location = locations
        validate_named_file(source_location, source)
        move_file(source_location, destination_location, destination)


def link_ack(source: Location, destination: Location) -> None:
    source_parent, source_name = source
    destination_parent, destination_name = destination
    os.link(source_name, destination_name, src_dir_fd=source_parent, dst_dir_fd=destination_parent, follow_symlinks=False)
    os.fsync(destination_parent)
    if os.environ.get("LBWC_TMUX_FS_FAIL_AFTER_ACK_LINK") == "1":
        fail("injected acknowledgement interruption after link")


def validate_ack_pair(source_fd: int, destination_fd: int, destination: str) -> None:
    source_info = os.fstat(source_fd)
    destination_info = os.fstat(destination_fd)
    if (source_info.st_dev, source_info.st_ino) != (destination_info.st_dev, destination_info.st_ino):
        fail(f"acknowledgement destination conflicts: {destination}")


def finish_ack(locations: LocationPair, descriptors: DescriptorPair, paths: PathPair) -> None:
    source, destination = locations
    source_fd, destination_fd = descriptors
    source_path, destination_path = paths
    if source_fd is not None:
        private_file(source_fd, source_path)
    if destination_fd is not None:
        private_file(destination_fd, destination_path)
    if source_fd is None and destination_fd is None:
        fail(f"acknowledgement source is unavailable: {source_path}")
    if source_fd is not None and destination_fd is None:
        link_ack(source, destination)
    elif source_fd is not None and destination_fd is not None:
        validate_ack_pair(source_fd, destination_fd, destination_path)
    if source_fd is not None:
        os.unlink(source[1], dir_fd=source[0])
        os.fsync(source[0])
    os.fsync(destination[0])


def complete_ack_files(locations: LocationPair, paths: PathPair) -> None:
    source_fd = open_optional(locations[0])
    destination_fd = open_optional(locations[1])
    with held_pair((source_fd, destination_fd)):
        finish_ack(locations, (source_fd, destination_fd), paths)


def complete_ack(root: str, source: str, destination: str) -> None:
    with held_fd(open_root(root)) as root_fd, parent_pair(root_fd, source, destination) as locations:
        complete_ack_files(locations, (source, destination))


def read_document(location: Location, source: str) -> str:
    parent_fd, name = location
    with held_fd(os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)) as source_fd:
        private_file(source_fd, source)
        document = os.read(source_fd, 1024 * 1024).decode()
        json.loads(document)
    return document


def read_json(root: str, source: str) -> str:
    with parent_location(root, source, False) as location:
        return read_document(location, source)


def delete(root: str, relative: str) -> None:
    with parent_location(root, relative, False) as location:
        parent_fd, name = location
        validate_named_file(location, relative)
        os.unlink(name, dir_fd=parent_fd)
        os.fsync(parent_fd)


def ensure_directory(path: str) -> None:
    created = False
    try:
        os.mkdir(path, 0o700)
        created = True
    except FileExistsError:
        created = False
    except OSError:
        fail(f"cannot create directory: {path}")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        fail(f"cannot inspect directory: {path}")
    with held_fd(fd):
        if created:
            os.fchmod(fd, 0o700)
        private_directory(fd, path)


def check_directory(path: str) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        fail(f"private directory is unavailable: {path}")
    with held_fd(fd):
        private_directory(fd, path)


def check_directories(paths: list[str]) -> None:
    if not paths:
        fail("paths are required")
    for path in paths:
        check_directory(path)


def check_file(path: str) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        fail(f"private file is unavailable: {path}")
    with held_fd(fd):
        private_file(fd, path)


def json_timestamp(dir_fd: int, name: str) -> tuple[int, str] | None:
    if not name.endswith(".json") or name in {".", ".."} or "/" in name:
        return None
    file_fd = open_optional((dir_fd, name))
    if file_fd is None:
        return None
    with held_fd(file_fd):
        private_file(file_fd, name)
        return os.fstat(file_fd).st_mtime_ns, name


def sorted_json_names(dir_fd: int) -> list[tuple[int, str]]:
    timed: list[tuple[int, str]] = []
    for name in os.listdir(dir_fd):
        timestamp = json_timestamp(dir_fd, name)
        if timestamp is not None:
            timed.append(timestamp)
    timed.sort(reverse=True)
    return timed


def list_json(path: str) -> None:
    try:
        dir_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        fail(f"private directory is unavailable: {path}")
    with held_fd(dir_fd):
        private_directory(dir_fd, path)
        for _, name in sorted_json_names(dir_fd):
            print(name)


def probe(root: str) -> None:
    with held_fd(open_root(root)) as root_fd:
        private_directory(root_fd, root)
        probe_name = f".probe.{uuid.uuid4().hex}"
        probe_fd = os.open(probe_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
        os.close(probe_fd)
        os.unlink(probe_name, dir_fd=root_fd)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["write-json", "publish-directory", "move", "complete-ack", "read-json", "delete", "probe", "ensure-directory", "check-directory", "check-directories", "check-file", "list-json"])
    parser.add_argument("--root")
    parser.add_argument("--relative")
    parser.add_argument("--document")
    parser.add_argument("--source")
    parser.add_argument("--destination")
    parser.add_argument("--path")
    parser.add_argument("--paths", nargs="+")
    return parser.parse_args()


def validate_arguments(args: argparse.Namespace) -> None:
    if args.command == "check-directories":
        if not args.paths:
            fail("--paths is required")
        return
    if args.command in {"ensure-directory", "check-directory", "check-file", "list-json"}:
        if not args.path:
            fail("--path is required")
        return
    if not args.root:
        fail("--root is required")


def dispatch_root_command(args: argparse.Namespace) -> None:
    if args.command == "write-json":
        return write_json(args.root, args.relative, args.document)
    if args.command == "publish-directory":
        return publish_directory(args.root, args.relative, args.document)
    if args.command == "move":
        return move(args.root, args.source, args.destination)
    if args.command == "complete-ack":
        return complete_ack(args.root, args.source, args.destination)
    if args.command == "read-json":
        sys.stdout.write(read_json(args.root, args.source))
        return
    if args.command == "delete":
        return delete(args.root, args.relative)
    probe(args.root)


def main() -> None:
    args = parse_arguments()
    validate_arguments(args)
    path_commands = {
        "ensure-directory": ensure_directory,
        "check-directory": check_directory,
        "check-file": check_file,
        "list-json": list_json,
    }
    if args.command == "check-directories":
        check_directories(args.paths)
    elif args.command in path_commands:
        path_commands[args.command](args.path)
    else:
        dispatch_root_command(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"tmux private fs: {error}", file=sys.stderr)
        sys.exit(1)
