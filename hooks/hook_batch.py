import glob
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time


class BashBatch:
    def __init__(self, stdin_text):
        self.directory = tempfile.TemporaryDirectory(prefix="meridian-hooks-")
        self.root = Path(self.directory.name)
        (self.root / "input").write_text(stdin_text, errors="surrogateescape")
        scripts = Path(__file__).resolve().parent.parent / "scripts"
        environment = dict(os.environ)
        environment.pop("CDPATH", None)
        environment["MERIDIAN_DISPATCH_LOGGING"] = "1"
        self.scripts = scripts
        self.process = subprocess.Popen(
            ["bash", str(scripts / "hook-batch.sh"), str(self.root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=environment, bufsize=0,
            start_new_session=True,
        )
        self.guard_pid = None
        self.broken = False

    def _target(self, name):
        plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
        candidates = [Path(plugin_root) / "scripts" / name] if plugin_root else []
        candidates.extend(Path(path) for path in sorted(glob.glob(
            "/tmp/.lbwc-plugin-root-link-*/scripts/" + name)))
        candidates.append(self.scripts / name)
        return next((path for path in candidates if path.is_file()), None)

    def _line(self, deadline):
        stdout = self.process.stdout
        if stdout is None:
            raise RuntimeError("bash runner output unavailable")
        remaining = max(0, deadline - time.monotonic())
        if not select.select([stdout], [], [], remaining)[0]:
            raise TimeoutError("guard timed out")
        line = stdout.readline()
        if not line:
            raise RuntimeError("bash runner exited")
        return int(line)

    def _kill_guard(self):
        if self.guard_pid is not None:
            try:
                os.killpg(self.guard_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.guard_pid = None

    def run(self, name, timeout) -> tuple:
        target = self._target(name)
        if target is None:
            return 2, "", f"hook target resolution failed: unable to locate '{name}'\n"
        deadline = time.monotonic() + timeout
        try:
            stdin = self.process.stdin
            if stdin is None:
                raise RuntimeError("bash runner input unavailable")
            stdin.write(os.fsencode(target) + b"\0")
            stdin.flush()
            self.guard_pid = self._line(deadline)
            status = self._line(deadline)
            self.guard_pid = None
        except TimeoutError:
            self._kill_guard()
            self._drain_timeout()
            status = 124
        finally:
            self._kill_guard()
        return self._output(status)

    def _drain_timeout(self):
        try:
            self._line(time.monotonic() + 1)
        except Exception:
            self.broken = True

    def _output(self, status):
        try:
            stdout = (self.root / "stdout").read_text(errors="replace")
            stderr = (self.root / "stderr").read_text(errors="replace")
            return status, stdout, stderr
        except OSError:
            if status == 2:
                return 2, "", "meridian hook warning: hook-batch.sh output unavailable, call allowed\n"
            return 1, "", ""

    def _stop_runner(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait()

    def _close_output(self):
        try:
            if self.process.stdout:
                self.process.stdout.close()
        finally:
            self.directory.cleanup()

    def close(self) -> None:
        try:
            self._kill_guard()
        finally:
            try:
                self._stop_runner()
            finally:
                self._close_output()
