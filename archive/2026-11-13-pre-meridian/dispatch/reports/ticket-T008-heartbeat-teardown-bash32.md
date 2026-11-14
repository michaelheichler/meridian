# T008 Heartbeat sender teardown waits for the interval under bash 3.2

Status is open. It reproduces in three runs. One is the full bash 3.2 suite on 1d4d55b, test 343. The others are the T005 full bash 3.2 run and its serial bash 3.2 retry. Modern bash passes the same rows when they run alone.

## Finding

- Row `teardown-stops-recorded-sender` in `tests/tmux-orchestrator.bats` (heartbeat table) fails the assertion at `tests/heartbeat_process_fixture.py:173`. Teardown took two seconds or more, so the sender kept running until its interval sleep ended.
- In the serial retry, row `resets-failure-count` passed its check and then crashed in fixture cleanup at `tests/heartbeat_process_fixture.py:196`. Cleanup parsed an empty `sleep_pid` file and raised ValueError.

## Likely causes

1. Production code. Bash 3.2 runs a trap only after a foreground child exits. If the sender sleeps in the foreground, a TERM waits for the sleep to end. Teardown kills the recorded sleep child, but the sender can start a new sleep between the PID read and the kill.
2. The test fixture reads the `sleep_pid` file while the sender is still writing it.

## Plan

- A coder makes the sender react to TERM at once under both shells, for example `sleep "$interval" & wait "$!"` with a trap that kills the current sleep child, and writes the sleep PID atomically.
- A test writer makes the fixture read the PID file only after it holds a complete number.

## Diagnosis on 2026-11-03

The sender is not slow. A timed bash 3.2 run shows the kill-agent command takes about 2.75 seconds. Authentication, registry work, pane teardown and route writes use that time before TERM. The sender then exits and reaps its sleep child within about 20 ms. Modern bash under load fails the same row for the same reason.

The fixture assertion at `tests/heartbeat_process_fixture.py:173` times the whole command, so it measures machine speed. Production needs no change. A test writer replaces the bound with a 30-second interval, keeps the 8-second teardown timeout and checks that the sender and child are gone. The same writer makes the fault shim publish its PID by rename and adds a HUP row. Phase evidence lives in `/tmp/t008-phases.log`.

## Done when

The heartbeat table passes ten runs in a row under `bash scripts/dev/bats32.sh` and under modern bash while another suite runs.
