#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import unittest
from types import ModuleType
from unittest import mock


def load_helper() -> ModuleType:
    path = os.path.join(os.path.dirname(__file__), "..", "scripts", "lib", "tmux-private-fs.py")
    spec = importlib.util.spec_from_file_location("tmux_private_fs", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TmuxPrivateFilesystemTests(unittest.TestCase):
    def create_fixture(self) -> None:
        self.helper = load_helper()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = self.temp.name
        os.chmod(self.root, 0o700)
        os.mkdir(os.path.join(self.root, "inbox"), 0o700)
        os.mkdir(os.path.join(self.root, "acked"), 0o700)
        self.helper.write_json(self.root, "inbox/job.json", json.dumps({"message": "source"}))

    def test_move_does_not_replace_existing_destination(self) -> None:
        self.create_fixture()
        self.helper.write_json(self.root, "acked/job.json", json.dumps({"message": "destination"}))
        with self.assertRaises(RuntimeError):
            self.helper.move(self.root, "inbox/job.json", "acked/job.json")
        with open(os.path.join(self.root, "inbox", "job.json")) as source:
            self.assertEqual(json.load(source)["message"], "source")

    def test_read_json_preserves_the_private_descriptor(self) -> None:
        self.create_fixture()
        self.helper.write_json(self.root, "credentials/bootstrap.json", json.dumps({"credential": "secret"}))

        document = self.helper.read_json(self.root, "credentials/bootstrap.json")

        self.assertEqual(json.loads(document)["credential"], "secret")
        self.assertTrue(os.path.exists(os.path.join(self.root, "credentials", "bootstrap.json")))

    def test_publish_directory_removes_staging_directory_after_contention(self) -> None:
        self.create_fixture()
        self.helper.publish_directory(self.root, "locks/registry.lock", json.dumps({"pid": 1}))
        with self.assertRaises(FileExistsError):
            self.helper.publish_directory(self.root, "locks/registry.lock", json.dumps({"pid": 2}))
        entries = os.listdir(os.path.join(self.root, "locks"))
        self.assertEqual(entries, ["registry.lock"])

    def test_complete_ack_resumes_after_both_names_interruption(self) -> None:
        self.create_fixture()
        with mock.patch.dict(os.environ, {"MERIDIAN_TMUX_FS_FAIL_AFTER_ACK_LINK": "1"}):
            with self.assertRaises(RuntimeError):
                self.helper.complete_ack(self.root, "inbox/job.json", "acked/job.json")
        self.assertTrue(os.path.exists(os.path.join(self.root, "inbox", "job.json")))
        self.assertTrue(os.path.exists(os.path.join(self.root, "acked", "job.json")))

        self.helper.complete_ack(self.root, "inbox/job.json", "acked/job.json")

        self.assertFalse(os.path.exists(os.path.join(self.root, "inbox", "job.json")))
        with open(os.path.join(self.root, "acked", "job.json")) as acknowledged:
            self.assertEqual(json.load(acknowledged)["message"], "source")

    def test_complete_ack_accepts_an_orphaned_destination(self) -> None:
        self.create_fixture()
        self.helper.move(self.root, "inbox/job.json", "acked/job.json")

        self.helper.complete_ack(self.root, "inbox/job.json", "acked/job.json")

        self.assertTrue(os.path.exists(os.path.join(self.root, "acked", "job.json")))

    def assert_rejection_releases_descriptors(self, row: tuple) -> None:
        operation, arguments, error = row
        before = len(os.listdir("/dev/fd"))
        with self.assertRaises(error):
            operation(*arguments)
        self.assertEqual(len(os.listdir("/dev/fd")), before)

    def test_rejected_operations_release_descriptors(self) -> None:
        self.create_fixture()
        good = os.path.join(self.root, "inbox")
        bad = os.path.join(self.root, "world")
        os.mkdir(bad, 0o755)
        os.symlink("../inbox/job.json", os.path.join(self.root, "acked", "job.json"))
        rows = (
            ("directory-set-not-private", self.helper.check_directories, ([good, bad],), RuntimeError),
            ("child-directory-not-private", self.helper.read_json, (self.root, "world/job.json"), RuntimeError),
            ("destination-parent-unavailable", self.helper.move,
             (self.root, "inbox/job.json", "unavailable/job.json"), FileNotFoundError),
            ("ack-destination-symlink", self.helper.complete_ack,
             (self.root, "inbox/job.json", "acked/job.json"), OSError),
        )
        for label, operation, arguments, error in rows:
            with self.subTest(label=label):
                self.assert_rejection_releases_descriptors((operation, arguments, error))

    def test_list_json_returns_newest_private_files_first(self) -> None:
        self.create_fixture()
        inbox = os.path.join(self.root, "inbox")
        self.helper.write_json(self.root, "inbox/old.json", json.dumps({"n": 1}))
        self.helper.write_json(self.root, "inbox/spaced name.json", json.dumps({"n": 2}))
        os.utime(os.path.join(inbox, "old.json"), ns=(1_000_000_000, 1_000_000_000))
        os.utime(os.path.join(inbox, "job.json"), ns=(2_000_000_000, 2_000_000_000))
        os.utime(os.path.join(inbox, "spaced name.json"), ns=(3_000_000_000, 3_000_000_000))
        with mock.patch.object(self.helper, "print") as printer:
            self.helper.list_json(inbox)
        names = [call.args[0] for call in printer.call_args_list]
        self.assertEqual(names, ["spaced name.json", "job.json", "old.json"])

    def test_list_json_enumerates_the_opened_directory_fd(self) -> None:
        self.create_fixture()
        inbox = os.path.join(self.root, "inbox")
        decoy = os.path.join(self.root, "decoy")
        os.mkdir(decoy, 0o700)
        self.helper.write_json(self.root, "decoy/decoy.json", json.dumps({"n": 2}))
        original_listdir = self.helper.os.listdir

        def listdir_after_path_swap(target) -> list[str]:
            if target == inbox:
                os.rename(inbox, inbox + ".orig")
                os.rename(decoy, inbox)
            return original_listdir(target)

        names = []
        with mock.patch.object(self.helper.os, "listdir", side_effect=listdir_after_path_swap):
            with mock.patch.object(self.helper, "print") as printer:
                self.helper.list_json(inbox)
                names = [call.args[0] for call in printer.call_args_list]
        self.assertIn("job.json", names)
        self.assertNotIn("decoy.json", names)


if __name__ == "__main__":
    unittest.main()
