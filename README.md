<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/meridian-hero-dark.png">
    <img src="assets/meridian-hero.png" alt="Meridian. Log. Explore. Orchestrate." width="760">
  </picture>
</p>

With the helper tool Meridian, you direct Claude Code to log, explore, and orchestrate with more ease. Agents no longer forget the work between steps and sessions, because Meridian keeps a logbook. Like a true explorer, it records each step and tells your agent team what is done and what comes next.

<p align="center"><img src="assets/pills/row.png" alt="Subagents, books, guard, trace, and explore." width="640"></p>

## The loop

You type one command, and Meridian takes the project one correct step forward.

| Step | What happens |
| :---: | --- |
| <img src="assets/icons/compass.png" alt="" width="40"><br>1 | You run `/meridian:transit`. Meridian reads the project state and finds the next missing piece, such as a plan or a test result. It asks you before it starts. |
| <img src="assets/icons/book-skills.png" alt="" width="40"><br>2 | Meridian generates a fresh agent definition for the job, and that agent reads its book-based skills before it touches a file. |
| <img src="assets/icons/team.png" alt="" width="40"><br>3 | An engineer builds while a separate critic reviews, so no agent ever approves its own work. |
| <img src="assets/icons/guard.png" alt="" width="40"><br>4 | Shell guards check every write, command, and spawn against the agent's contract before anything reaches your repository. |
| <img src="assets/icons/logbook.png" alt="" width="40"><br>5 | The logbook records what happened and what comes next, so the next agent or session continues without guessing. |

## Features

| Area | What you get |
| :---: | --- |
| <img src="assets/icons/team.png" alt="" width="32"><br>**Teams** | Every spawn gets its own agent definition, bound to a contract from the shell. Meridian picks a solo specialist, a pair of engineer and critic, or a trio with a test owner. |
| <img src="assets/icons/book-skills.png" alt="" width="32"><br>**Skills** | Each role reads the book-based skills that ship with Meridian before it works, so it knows its job instead of guessing it. These skills do not depend on native Claude Code skills. |
| <img src="assets/icons/guard.png" alt="" width="32"><br>**Guards** | File, command, spawn, and task guards enforce each contract. An explicit deny blocks a call. A guard that fails only warns, so a broken check never stalls your session. |
| <img src="assets/icons/logbook.png" alt="" width="32"><br>**Logbooks** | The explorer journal keeps the request, the decisions, and the next step. It survives compaction and the end of a session, and it never deletes an entry. |
| <img src="assets/icons/explore.png" alt="" width="32"><br>**Research** | Meridian studies the codebase and the question first, so plans rest on evidence from your repository. |
| <img src="assets/icons/git.png" alt="" width="32"><br>**Git** | The main session owns every commit, one per task, and agents can work in isolated worktrees. |
| <img src="assets/icons/build.png" alt="" width="32"><br>**Phases** | Each phase moves through a reviewed plan, contract-bound building, a QA verdict, and your own acceptance test. |
| <img src="assets/icons/compass.png" alt="" width="32"><br>**Status** | The statusline shows the phase, the team, and the checks. Every step ends with a short card that names the next action. |

Meridian runs on local files and small scripts written for the bash that ships with macOS, so it needs no server or account.

## Guard source development

Guard source protection covers the installed `hooks/` and `scripts/` trees, including new files and directory replacement. Meridian protects the canonical `CLAUDE_PLUGIN_ROOT` and the installation that runs the hook, so changing the environment does not unprotect the running copy. It follows symlinks. If root resolution fails, protection falls back to guard names everywhere. Agents may edit, write, and stage same-named files in another checkout, but they may not execute decision runtime scripts or hook modules from any location.

For a single read-only inspection command, path checks keep fully quoted glob tokens literal. A Git pathspec such as `git -C /path/to/project ls-files 'tmp/**'` does not trigger a recursive filesystem scan. Mutations, compound commands, comments, and ambiguous quoting keep the existing glob expansion and limit.

Embedded interpreter checks keep pipelines together but inspect separate shell commands independently. Comments, heredocs, and ambiguous tokenization keep the conservative whole-command check.

SessionStart prints the owner CLI command with the absolute installed path. To patch the installed copy, copy that command into an owner `!` shell and append `allow --for 8h`. A terminal works too, and neither shell needs `CLAUDE_PLUGIN_ROOT`. Durations use whole minutes or hours, such as `30m` or `8h`, and cannot exceed `12h`. Use `status` to inspect the grant or `revoke` to remove it.

The CLI stores an absolute expiry in `~/.local/state/meridian-guard/grant.json`, outside project state. The state directory and grant must belong to the current user and allow no access for other users. Expired or malformed grants allow nothing. An active grant lets agents edit, write, and stage installed guard source. SessionStart adds one line with the grant expiry. Agents cannot modify the installed unlock CLI, run any copy of it, import its Python module, or access grant state. Plain reads and development edits of CLI source in another checkout remain available. Owner `!` commands bypass PreToolUse and can manage the grant.

The unlock never permits access to decision runtime state. Meridian continues to protect `.meridian/.runtime`, `.runtime/decisions`, `.hook-transitions`, and pending decision records in every project.

These checks provide agent guardrails, not a security boundary against a hostile process. Same-user code can forge grants through indirect names, and renamed copies or string-built names can escape text-level checks. The unlock records owner intent but cannot authenticate every action by a process that already shares the owner account.

## Quick start

After you add the marketplace and install the plugin, restart Claude Code.

```bash
claude plugin marketplace add michaelheichler/meridian
claude plugin install meridian@meridian-marketplace
```

Open your project in Claude Code and set it up once.

```text
/meridian:init
```

From then on, one command drives the work.

```text
/meridian:transit
```

Meridian tells you what it found, what it wants to do next, and what it needs from you. Answer the question, and it runs the step.

## Using Meridian day to day

You stay the decision maker. Meridian proposes the next step, and you approve it or change it. You can stop at any point. When a phase needs your judgment, such as accepting finished work, Meridian walks you through it one checkpoint at a time.

When you come back after a break, run `/meridian:transit` again. Meridian reads its logbook and the Git history, and it picks up where the work stopped.

## Commands

You only need `/meridian:transit`. The other commands let you run one stage directly.

| Command | What it does |
| --- | --- |
| `/meridian:init` | Sets up Meridian in a project. |
| `/meridian:transit` | Finds the next step and runs it after you approve. |
| `/meridian:status` | Shows progress, the current phase, and the next action. |
| `/meridian:plan` | Plans one phase. |
| `/meridian:build` | Builds a planned phase with contract-bound agents. |
| `/meridian:qa` | Checks finished phase work. |
| `/meridian:uat` | Walks you through acceptance testing. |
| `/meridian:research` | Runs research for a question. |
| `/meridian:map` | Maps the codebase. |
| `/meridian:debug` | Investigates a bug step by step. |
| `/meridian:fix` | Applies a small change with commit discipline. |
| `/meridian:team` | Forms an agent team for one scoped task. |
| `/meridian:config` | Shows and changes every option. |
| `/meridian:help` | Lists every command. |

Run `/meridian:help` for the full list, including pause, resume, todos, models, and profiles.

## Learn more

- [Architecture](PUBLIC-ARCHITECTURE.md) explains how the parts work together.
- The [`/meridian:config` reference](commands/config.md) lists every option.
- [Changelog](CHANGELOG.md) shows what changed.

---

<sub>Released under the MIT License. Thanks to the VBW team for the foundation.</sub>
