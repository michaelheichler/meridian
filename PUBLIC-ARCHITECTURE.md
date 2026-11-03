# MERIDIAN Public Architecture

MERIDIAN is a Claude Code plugin for disciplined software delivery. The human owns direction, the main session owns orchestration, and generated agents receive only shell-issued work contracts.

## One user route

```text
/meridian:init once
    |
/meridian:transit for every next step
    |
MERIDIAN routes the active phase through planning, build, QA, and UAT
```

`/meridian:transit` reads the project state, identifies one missing artifact, asks for approval, and dispatches the route that owns that work. Users do not have to manage the pipeline stages themselves.

## System shape

```text
Human
  -> scope, priorities, acceptance, and release decisions
Main Claude Code session
  -> routing, contracts, artifact persistence, and Git
Shell control plane
  -> contract, capability, lifecycle, and artifact checks
Generated agents
  -> one bounded task and structured evidence
Project artifacts
  -> durable plans, results, and decisions
```

The control plane uses local files, small scripts, hooks, JSON, Markdown artifacts, and local locks. It does not require a server, queue, database, or remote telemetry service.

## Ownership model

| Owner | Owns | Does not own |
| --- | --- | --- |
| Human | Scope, priorities, approvals, UAT, release decisions | Routine orchestration work |
| Main session | Routing, contracts, artifact persistence, commits, Git | Worker implementation scope |
| Generated agent | One assigned task and its evidence | Planning authority, contract changes, Git, release actions |
| Shell guards | Checks and admission decisions | Product direction or autonomous planning |

Agent output is evidence, not authority. The framework protects the human from agent drift.

## Durable project state

MERIDIAN stores initialized workflow state under `.meridian/` in the target project. Authoritative team runs and import interviews can stage diagnostic state under `.temporary-agent-runfiles/` without initializing the project.

| Artifact | Purpose |
| --- | --- |
| `PROJECT.md` | Project identity and operating context |
| `REQUIREMENTS.md` | Accepted requirements |
| `ROADMAP.md` | Phases and completion state |
| `STATE.md` | Compact current-state summary |
| `phases/<phase>/PLAN.md` | Reviewed phase plan |
| `phases/<phase>/SUMMARY.md` | Build result and evidence |
| `phases/<phase>/VERIFICATION.md` | Main-session QA result |
| `phases/<phase>/UAT.md` | Human acceptance record |

`/meridian:transit` reads these artifacts in order. It stops at the first missing or invalid stage. It does not mark work complete from an agent claim alone.

## Task contracts

Before an agent starts, the main session creates a shell-owned contract. The contract binds:

- task identity and source plan digest
- selected role, team shape, and job
- exact repository-relative file paths for schema 2 contracts, or typed file and directory capabilities for schema 3 contracts
- allowed lifecycle transitions
- primary workspace

The generator checks the contract before it renders an agent definition or registers the agent. The spawn guard checks it again before work starts. The file guard checks it before every write reaches the workspace.

```text
planned -> dispatched -> running -> awaiting_review -> verified
                                      |
                                      -> blocked or cancelled
```

Invalid transitions fail closed. A worker cannot add paths, change roles, edit contract records, or promote its own result.

Schema 3 native-team contracts also bind runtime kind, communication policy, generated-definition authority, and native shared task identity. `TaskCreated` must bind one pending contract. `TaskCompleted` succeeds only after that bound contract reaches `verified`.

## Team boundaries

MERIDIAN uses the smallest team that matches the work:

- A solo specialist handles a bounded planning, research, QA, debug, or documentation task.
- An engineer and critic pair handles implementation and independent review.
- If the task has separate test-path ownership, a trio adds `test-dev`.
- `/meridian:team` forms a Claude Code native team after the main session shows the roster and scope and the user approves them.

Only one generated grouping is active at a time. The next grouping waits until every current member is `used` or `expired`. After Claude Code spawns the first teammate, the native team exists. MERIDIAN never calls `TeamCreate`, passes deprecated `team_name`, or edits native team configuration. Critics have no write allowance. Test owners receive test paths only. The main session owns commits and final artifact writes.

## External plan import

`/meridian:import` parses external planning sources into schema 1 normalized IR. The GSD adapter is fixture-verified. Generic Markdown is visibly unverified and capped by file count and bytes. Source text is inert data. Staging, preview, and conflict decisions occur before promotion. Promotion accepts an explicit artifact list, writes atomically, persists provenance, and rolls back selected destinations on failure.

## Enforcement

| Boundary | Protects | Enforcement |
| --- | --- | --- |
| Contract checks | Task, role, team, path, and plan identity | Contract writer, generator, spawn guard |
| File capability | Exact writes in the primary workspace | File guard on Write, Edit, and NotebookEdit |
| Test ownership | Product code and test-path separation | Test scope guard and contracts |
| Worker lifecycle | Active work, idle expiry, exclusive admission | Manifest lock and lifecycle script |
| Native task binding | Task identity and verified completion | TaskCreated and TaskCompleted hooks |
| Command admission | Git, shell evaluation, critical commands, control paths | Bash guard |
| Main-session persistence | Verification and remediation artifacts | Deterministic writers and locked state scripts |

Command admission is not an operating-system sandbox. It blocks recognized generated-agent command routes and protected control paths. MERIDIAN does not claim that a lexical shell check can confine every arbitrary executable or child process.

## Quality and evidence

Agents return typed handoffs and evidence. The main session checks that material before it changes durable state.

- The `lead-critic` checks plans before build work begins.
- Build summaries identify completed task evidence.
- QA returns a structured verdict. The main session writes `VERIFICATION.md`.
- UAT remains a human checkpoint.
- Failed QA or UAT opens a bounded remediation round with explicit stage state.

The DevIQ ledger records local decisions, evidence, and blocks in append-only hash-chained JSONL files. It is advisory. It neither routes work nor grants permissions, and it never accepts a phase.

## Status and telemetry

The statusline is read-only. If Claude Code supplies status fields, it reads them and combines them with local project state. It shows phase progress, team status, QA or UAT state, and telemetry health. It does not call an API or read credentials.

MERIDIAN observes an idle teammate for 120 seconds, then checks the manifest, contract, and idle token again before returning native stop guidance. It never sends process signals, deletes output, or clears ownership without a valid state transition.

Session telemetry is local and advisory. The main session writes bounded, hash-chained events. Events never contain prompts, transcripts, tool payloads, secrets, or uploaded data.

## Distribution and release

The repository is a Claude Code marketplace. Its `.claude-plugin/` manifest declares MERIDIAN and remains versioned.

Release metadata stays synchronized across `VERSION`, plugin metadata, marketplace metadata, and `CHANGELOG.md`. `scripts/release-verify.sh` checks local release readiness. Publishing, tagging, history changes, and repository visibility remain explicit maintainer actions.

## Local checks

Run the local checks with:

```bash
claude plugin validate --strict .
bats tests/
bats tests/self-check.bats
bash scripts/tests/agent-generator-core.sh
bash scripts/release-verify.sh
```

These checks cover the local plugin and control plane. They do not claim a hosted service, a remote execution environment, or a universal process sandbox.
