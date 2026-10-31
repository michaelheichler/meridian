# Tests

bats-core is the test harness for all new `.bats` coverage in this repo, mirroring the convention documented in VBW's `testing/README.md` and `.github/workflows/ci.yml` (VBW's CI installs it via `git clone --depth 1 --branch <tag> https://github.com/bats-core/bats-core.git && sudo install.sh /usr/local`). Locally, `brew install bats-core` on macOS or the `bats` npm package are the standard equivalents.

Install locally with one of:

- `brew install bats-core`
- `npm install -g bats`

Then run a `.bats` file directly: `bats tests/some-thing.bats`.

## What stays as-is

- `scripts/tests/agent-generator-core.sh` is a hand-rolled pass/fail script. This pass leaves it as a script, and it keeps working exactly as it does today (`bash scripts/tests/agent-generator-core.sh`). `tests/self-check.bats` replaced the former `tests/self-check.sh` (`bats tests/self-check.bats`).

## What's new

New test coverage for transferred or newly hardened scripts should be written as `.bats` files under `tests/`, not as additional hand-rolled shell scripts. This keeps future coverage on one harness instead of two.
