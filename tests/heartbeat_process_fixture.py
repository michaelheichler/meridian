import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import tempfile
from types import SimpleNamespace
from typing import Callable, TypeVar

Result = TypeVar("Result")


def wait_until(predicate: Callable[[], Result], timeout=8) -> Result:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("timed out waiting for " + predicate.__name__)


def read_json(path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def alive(pid) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def event_count(fixture) -> int:
    return len(fixture.events.read_text().splitlines()) if fixture.events.exists() else 0


def make_fixture() -> SimpleNamespace:
    scenario, root, control, scratch, binary, capability, main_capability = sys.argv[1:]
    scratch = Path(tempfile.mkdtemp(prefix="heartbeat-", dir=scratch))
    control = str(Path(control).resolve())
    fixture = SimpleNamespace(
        scenario=scenario, root=Path(root), control=Path(control), scratch=scratch,
        binary=binary, capability=capability, main_capability=main_capability,
        events=scratch / "heartbeat-events", children=[],
        record=Path(control) / ".runtime/tmux-bus/inboxes/agent-a/heartbeat-sender.json",
        sleep_pid=scratch / "heartbeat-sleep-pid",
    )
    fixture.env = dict(os.environ, PATH=binary + os.pathsep + os.environ["PATH"])
    fixture.command_env = fixture.env.copy()
    configure_shims(fixture)
    return fixture


def configure_shims(fixture) -> None:
    shim = fixture.scratch / "heartbeat-bin"
    shim.mkdir()
    for name in ("bash", "jq", "sleep"):
        executable = shutil.which(name, path=fixture.env["PATH"])
        if executable is None:
            raise RuntimeError("missing executable " + name)
        fixture.env["HB_REAL_" + name.upper()] = executable
        shutil.copy(fixture.root / "tests" / ("heartbeat_fault_" + name + ".bash"), shim / name)
        (shim / name).chmod(0o755)
    fixture.env.update(
        PATH=str(shim) + os.pathsep + fixture.env["PATH"], HB_SCENARIO=fixture.scenario,
        HB_EVENTS=str(fixture.events), HB_SUCCESSES=str(fixture.scratch / "heartbeat-successes"),
        HB_READS=str(fixture.scratch / "heartbeat-reads"),
        HB_REGISTRY=str(fixture.control / ".runtime/tmux-bus/registry.json"),
        HB_SLEEP_PID=str(fixture.sleep_pid),
    )


def start_sender(fixture) -> subprocess.Popen:
    log = open(fixture.scratch / "heartbeat-process.log", "w")
    process = subprocess.Popen(
        [fixture.env["HB_REAL_BASH"], str(fixture.root / "scripts/tmux-agent-heartbeat.sh"),
         str(fixture.control), "agent-a", "agent-session"],
        stdin=subprocess.PIPE, stdout=log, stderr=log, env=fixture.env,
    )
    fixture.children.append(process)
    if process.stdin is None:
        raise RuntimeError("sender capability pipe is unavailable")
    process.stdin.write(Path(fixture.capability).read_bytes())
    process.stdin.close()
    log.close()
    return process


def recorded_sleep_pid(fixture) -> int | None:
    try:
        text = fixture.sleep_pid.read_text().strip()
    except OSError:
        return None
    if not text.isascii() or not text.isdecimal() or int(text) <= 0:
        return None
    return int(text)


def sender_sleep(fixture, process) -> int:
    def sleeping() -> int | None:
        pid = recorded_sleep_pid(fixture)
        if pid is None:
            return None
        parent = subprocess.run(["ps", "-p", str(pid), "-o", "ppid="],
                                capture_output=True, text=True).stdout.strip()
        return pid if parent == str(process.pid) else None
    child = wait_until(sleeping)
    if child is None:
        raise RuntimeError("sender sleep identity is unavailable")
    return child


def failure_sequence(fixture) -> None:
    process = start_sender(fixture)
    if fixture.scenario == "recovery":
        wait_until(lambda: event_count(fixture) >= 6 or process.poll() is not None)
        assert process.poll() is None, "sender exited before both recovery cycles"
        assert event_count(fixture) >= 6, "sender did not reach the second recovery"
        successes = fixture.scratch / "heartbeat-successes"
        wait_until(lambda: successes.exists() and len(successes.read_text().splitlines()) >= 2)
        assert process.poll() is None, "sender stopped after the second successful heartbeat"
        return
    assert process.wait(timeout=8) == 1, "failure limit must exit unsuccessfully"
    expected = {"exhausted": 3, "mixed": 2}[fixture.scenario]
    assert event_count(fixture) == expected, (
        f"expected {expected} bus attempts, observed {event_count(fixture)}")


def interrupt_sleep(fixture) -> None:
    process = start_sender(fixture)
    child = sender_sleep(fixture, process)
    process.send_signal(getattr(signal, "SIG" + fixture.scenario))
    process.wait(timeout=1.5)
    wait_until(lambda: not alive(child), timeout=1)


def teardown_agent(fixture) -> None:
    registry = read_json(fixture.control / ".runtime/tmux-bus/registry.json")
    if registry is None:
        raise RuntimeError("agent registry is unavailable")
    target = registry["agents"][0]["tmux_target"]
    command = ["bash", str(fixture.root / "scripts/tmux-agent-orchestrator.sh"), "kill-agent",
               "--project-root", str(fixture.control.parent), "--control-root", str(fixture.control),
               "--target", target, "--orchestrator-id", "main-session",
               "--orchestrator-session-id", "main-session",
               "--orchestrator-capability", fixture.main_capability]
    subprocess.run(command, env=fixture.command_env, check=True, capture_output=True, timeout=8)


def change_identity(fixture, record) -> subprocess.Popen | None:
    if fixture.scenario == "stale-start":
        record["started"] = "not the current process start"
    if fixture.scenario != "stale-command":
        return None
    dummy = subprocess.Popen(["sleep", "3"])
    fixture.children.append(dummy)
    record["pid"] = dummy.pid
    record["started"] = subprocess.check_output(
        ["ps", "-p", str(dummy.pid), "-o", "lstart="], text=True).rstrip("\n")
    return dummy


def teardown_sender(fixture) -> None:
    process = start_sender(fixture)
    child = sender_sleep(fixture, process)
    record = {"pid": process.pid, "started": subprocess.check_output(
        ["ps", "-p", str(process.pid), "-o", "lstart="], text=True).rstrip("\n")}
    dummy = change_identity(fixture, record)
    fixture.record.write_text(json.dumps(record))
    fixture.record.chmod(0o600)
    teardown_agent(fixture)
    if fixture.scenario == "matching":
        process.wait(timeout=1)
        assert not alive(process.pid), "teardown left the heartbeat sender running"
        assert not alive(child), "teardown left the heartbeat sleep child running"
    elif fixture.scenario == "stale-command":
        assert dummy is not None and dummy.poll() is None, "teardown signalled an unrelated process"
    else:
        assert process.poll() is None, "teardown signalled a stale start identity"


def stop_process(process) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=1)


def cleanup(fixture) -> None:
    for process in fixture.children:
        stop_process(process)
    pid = recorded_sleep_pid(fixture)
    if pid is not None and alive(pid):
        os.kill(pid, signal.SIGTERM)


def main() -> None:
    fixture = make_fixture()
    try:
        actions: dict[str, Callable] = dict.fromkeys(("recovery", "exhausted", "mixed"), failure_sequence)
        actions.update(dict.fromkeys(("TERM", "INT", "HUP"), interrupt_sleep))
        actions.get(fixture.scenario, teardown_sender)(fixture)
        print(fixture.scenario + " passed")
    except Exception:
        log = fixture.scratch / "heartbeat-process.log"
        print(log.read_text() if log.exists() else "sender did not launch", file=sys.stderr)
        raise
    finally:
        cleanup(fixture)
        shutil.rmtree(fixture.scratch)


if __name__ == "__main__":
    main()
