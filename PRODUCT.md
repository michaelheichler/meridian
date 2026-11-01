# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The product itself is a Claude Code plugin that runs in a terminal. Its designed surfaces are the GitHub README (rendered markdown) and the markdown that Claude Code renders in chat. The chat surfaces are the per-step feedback card, the status card, and the statusline.

## Users

The owner comes first. He is a developer who builds software with Claude Code agents and wants planning, build, QA, and UAT to run in a disciplined loop. The README also serves a GitHub visitor who decides in under a minute whether to install the plugin. That visitor uses Meridian as a human at the keyboard, not as an agent.

## Product Purpose

Meridian (renamed from LBWC in Group E of the 2.0 plan) turns one command into the next correct step of a software project. It reads project state, finds the one missing artifact, asks for approval, and routes the work through planning, build, QA, and UAT with generated agents. Success means the human owns direction and approvals, while agents do bounded work that the main session checks before it changes durable state.

## Positioning

The agent-invocation core combines three mechanisms.

1. A generative agent pipeline writes a fresh, contract-bound agent definition for each spawn.
2. File-based skill grounding makes each role read its book-based skills before it works. These books ship with the plugin and are not native Claude Code skills.
3. Enforced worker and critic pairing means an engineer never reviews its own work, and the critic has no write access.

Shell guards enforce every contract before a write or spawn reaches the workspace. Logbooks give a clean handover from one agent or session to the next. The logbooks are the explorer journal and the verification trail.

## Operating Context

The user works in a terminal with Claude Code. The daily loop is `/meridian:init` once, then `/meridian:transit` for every next step. Durable state lives in markdown and JSON under the planning directory. The plugin uses local files, small bash scripts, hooks, and local locks. It needs no server, queue, database, or remote telemetry.

## Capabilities and Constraints

- One command reads state and dispatches the stage that owns the missing artifact.
- Agents come as solo specialists, engineer and critic pairs, and trios with a test owner. The generator writes each agent fresh per spawn from a shell-issued contract.
- File, bash, spawn, task-admission, and task-completion guards check every call. Only an explicit deny blocks a call, and a crashing guard warns and allows.
- The logbooks are the append-only explorer journal, the verification records, and local hash-chained telemetry.
- The runtime is bash that runs on macOS `/bin/bash` 3.2, plus one Python hook dispatcher.
- The brand board names five capabilities. "subagents" means generated agent teams. "books" means the book-based skills each role must read. "guard" means the shell guards. "trace" and "explore" mean the logbooks, plus the research and codebase mapping that feed them.
- The owner has not chosen the final tagline. "Log. Explore. Orchestrate." on the brand board is a draft.

## Brand Commitments

- The name is Meridian. Commands use the `/meridian:` prefix after the rename, and the driver command is `/meridian:transit`.
- The word "bearing" never appears anywhere.
- Meridian is its own product, so docs do not discuss its origins. One closing README line thanks the VBW team, and no other text names VBW.
- The voice is calm, precise, plain English, with no walls of text, no jokes, and no filler.
- The license gets one line at the bottom of the README.
- The owner's hand-illustrated brand board lives at `assets/brand/meridian-brand-board.png`. It holds the logo mark (orbit, star, open book), the wordmark, eight icons, five capability pills, and an app icon tile.

## Evidence on Hand

- The brand board image named above.
- The command set in `commands/`, the architecture in `PUBLIC-ARCHITECTURE.md`, and the test suite in `tests/`.
- No testimonials, user counts, benchmarks, or third-party endorsements exist, and future work must not invent them.

## Product Principles

1. The human decides. Agents propose and do bounded work, and the main session checks it.
2. Documented means working. Every documented option has code that reads it.
3. No feature is ever cut. Slimming means faster, more precise, and cheaper in tokens.
4. Show the next step. Every surface ends with what happens next and what the human must approve.
5. Plain over clever. Short sentences, real nouns, no marketing filler.
