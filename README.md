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

## Quick start

After you add the marketplace and install the plugin, restart Claude Code.

```bash
claude plugin marketplace add michaelheichler/lbwc
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
