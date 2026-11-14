# T001 Timing-dependent tests

Status is open until the Docker coverage run passes. The test fixes merged as b40aaa4 and 4891a0c on top of 240bb40. In the main tree the two-file command passes 21 of 21, and the filtered bus command passes in both recorded runs. The teardown race fix a39072e waits in the T002 branch.

## Failing runs

| Run | Tree | Result |
| --- | --- | --- |
| Full modern suite on 2d4dcb5 | `~/.cache/lbwc-cov/src-2d4dcb5` | 410 of 412 pass, tests 307 and 323 fail |
| `bats --tap tests/tmux-orchestrator.bats tests/lbwc-routing-lock.bats` | `fix-flaky` worktree with its unfinished edits | exit 1 |
| The same two files on 1f676fa | main tree | 21 of 21 pass |
| Coverage run in Docker on 47729a4 | `lbwc-coverage:5` | the teardown test and two routing lock tests fail every time |

## Findings

1. `attached external session teardown removes only the LBWC pane and runtime state` in `tests/tmux-orchestrator.bats`. The Docker failure sits at the topology assertion right after provisioning. The external pane starts the default login shell, so shell startup and the kcov `BASH_ENV` can change its state. Under load on macOS the kill status check failed once. The suspect is a race in production code at `scripts/lib/tmux-agent-orchestrator-teardown.sh:127-128`, where `kill-pane` runs and the existence check follows at once.
2. `publish delivers through a recorded transaction, authenticates principals, serializes one inbox and honours backpressure` in `tests/tmux-bus.bats`. The watcher in `bus_case_publish_backpressure_or_timeout` polls for a delivery lock that publish takes and releases on every busy-slot pass. The watcher can miss every pulse and never send the ack.
3. The two routing lock tests source production code through `bash -c`. Under kcov `BASH_SOURCE` is unbound there, so they fail in Docker only.

## Planned fix

- Start the external pane with `bash --noprofile --norc` and wait for a readiness marker.
- Replace the lock-pulse watcher with a handshake on observable delivery state.
- Run the routing probes from script files instead of `bash -c`.
- The bus test runs the second publish in the background, proves the wait through the still-running publisher and the undelivered message, then acks and asserts delivery.
- The teardown race lives in production code. The T002 coder fixes `scripts/lib/tmux-agent-orchestrator-teardown.sh:127-128` with bounded polling, because T002 changes the same file.

## Progress

- 63994d8 replaces the lock-pulse watcher. Under load it exposed a production race at `scripts/lib/tmux-bus-publish.sh:50-52`, where the remaining time could reach zero and the lock helper rejected it as `invalid lock timeout`.
- 240bb40 on the branch fixes that race. Both bus suites pass, 9 of 9 on modern bash and bash 3.2.
- 5d89b7b makes the pane start and the routing probes deterministic. All three tests pass ten runs in a row on modern bash, and the two files pass 21 of 21 under bash 3.2.

## Done when

- The two-file command above passes in the main tree after the merge.
- Each test passes ten runs in a row under parallel load on macOS.
- The Docker coverage run passes all three.
