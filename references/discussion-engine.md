# Discussion Engine

One engine has two entry points. `/meridian:transit` auto-dispatches here when phase detection reports `needs_discussion`, and `/meridian:discuss` invokes it directly. The user sets the vision, and the orchestrator builds it. The engine surfaces decisions that downstream agents (`lead`, engineers) need so they never ask the user again mid-phase. The main session runs it inline without spawning an agent.

## Shared decision boundary

Follow `references/ask-user-question.md`. The main session asks one bounded, single-select question at a time and pauses the workflow while it is pending. Recommendations guide the user, but do not create a decision. Generated agents return the escalation payload in `references/subagent-contracts.md` instead of asking the user or changing decision state.

## Step 1. Calibrate

Infer user sophistication without asking. Use conversation signals including language in prior messages (jargon vs plain), project description complexity, and whether they typed `/meridian:discuss` explicitly or arrived via `/meridian:transit`.

| Mode | Signals | Question style |
| --- | --- | --- |
| **Builder** | Plain language, non-technical framing | Scenario-based, cause-and-effect, no jargon |
| **Architect** | Technical terms, specific requirements | Direct, domain terms, trade-off framing |

## Step 1.5. Detect continuation

Check whether `{NN}-CONTEXT.md` already exists in the target phase directory.

- **No CONTEXT.md.** Start a fresh discussion.
- **CONTEXT.md exists.** Continue the discussion. Read it first, load existing `## Decisions Made` subsections as the baseline, and focus on topics those sections do not cover.

## Step 1.7. Assumptions path (optional)

As an alternative to the question-driven flow, read the codebase first, form evidence-backed assumptions, and present them for correction. This reduces interaction from many questions to a few corrections.

Activation, first match wins.

1. `--assumptions` in `$ARGUMENTS` → assumptions path
2. `discussion_mode` is `"assumptions"` in `.meridian/config.json` → assumptions path
3. `discussion_mode` is `"auto"` and `.meridian/codebase/META.md` exists → assumptions path
4. Otherwise → questions path (Step 2)

If the assumptions path activates but no codebase map exists, say so and fall back to questions. Explain that assumptions mode works best with codebase context and that `/meridian:map` can provide evidence for a later assumptions discussion.

**A1. Codebase analysis.** Read `.meridian/codebase/ARCHITECTURE.md`, `PATTERNS.md`, and `CONCERNS.md` when present, plus the phase goal from ROADMAP.md. For gray areas needing deeper evidence, read the actual source files, do not form assumptions from summaries alone when the source is readily available.

**A2. Form assumptions.** Identify gray areas the same way Step 2 does, then use this structure for each.

```
### [Gray Area Title]

**Assumption:** [What you conclude from codebase evidence]
**Evidence:** [File paths + specific code patterns]
**Confidence:** High (90%+) | Medium (60-90%) | Low (<60%)
**Consequence if wrong:** [What breaks or needs rework]
```

**A3. Present for correction.** Present one assumption at a time with its recommendation. High and medium confidence assumptions still need an explicit user confirmation. Low confidence assumptions are genuine questions and follow Step 3.

**A4. Process corrections.** When the user confirms an assumption, record it as the decision. For a correction, record the user's answer and preserve the original assumption as context. Native Other returns the typed correction directly, so update the assumption and ask for confirmation. A dismissed interaction records no decision and stops the workflow.

## Step 2. Orient

Read the phase goal from ROADMAP.md and ask which decisions could go multiple ways and change the implementation. Use no keyword matching or predefined templates.

Gray areas must be phase-specific and concrete. Avoid broad topics such as "UI decisions" or "Data handling". Prefer "Cold-start behavior for a user with no history" or "Dietary restrictions as strict filter vs soft preference".

Form a preliminary recommendation per area before asking anything. If a recommendation depends on codebase state, read the relevant files first, do not speculate about code you have not opened. Aim for 3-5 gray areas on a fresh discussion.

**Continuation mode.** Exclude areas that existing `## Decisions Made` subsections cover. Focus on topics the user did not select last time, second-order effects of prior decisions, and deferred ideas worth revisiting. Continuation selection must always offer an explicit `None: discussion is complete` path.

**Selection.** Present one gray area at a time. Use a structured single-select question only when there are 2-4 visible options. For a single fresh area, proceed to that area without a selection question. For 5-6 areas, use a numbered list and ask the user to name the next area in a plain-text reply, with no options array. Split a structured candidate list when adding continuation's explicit `None: discussion is complete` path would exceed four options. After resolving an area, ask whether to choose another area. For a fresh discussion, ask "Which area should we discuss first?" For a continuation, name the topics the previous discussion did not cover and ask which to explore first.

## Step 3. Explore

**Early exit.** If the user chooses `None: discussion is complete`, skip to Step 4, which then writes nothing.

For each selected area, hold a natural conversation rather than filling in a form.

1. Open with your recommendation. State the gray area, give the recommendation with 2-3 sentences of reasoning, and ask for confirmation. Put the recommended choice first with `(Recommended, [brief reason])` in the label, followed by 1-2 alternatives. Claude Code adds native Other.
2. If the user picks the recommendation, confirm in one line and move on.
3. If the user picks an alternative, record it. Follow up only if it changes a downstream requirement.
4. For native Other, process the typed answer, adjust, and confirm.
5. Move to the next area.

**Clear-cut decisions.** When a standard practice answer is obvious, state the recommendation and ask one confirmation question for that decision. Do not batch decisions.

**Scope awareness.** If the user mentions something outside the phase boundary, say "[Feature] sounds like its own phase. I'll note it." Record it under Deferred Ideas.

**Vague answers.** Ask a plain narrowing follow-up, such as "Fast in what way, page loads, search, or many users at once?"

## Step 4. Capture

Write or update `.meridian/phases/{NN}-{slug}/{NN}-CONTEXT.md` from `templates/CONTEXT.md`. Keep the `{NN}-` prefix because the `needs_discussion` check in `phase-detect.sh` only counts canonical `[0-9]*-CONTEXT.md` names.

**Continuation mode.** Do not overwrite. Append new `### [Gray Area]` subsections under `## Decisions Made` and new entries under Deferred Ideas. Never remove, rewrite, or reorder existing content, the original decisions still stand. If the user selected `None: discussion is complete`, write nothing.

**Assumptions-mode decisions** go under `## Decisions Made` with the evidence block the template's comment describes (`**Evidence:**`, `**Confidence:**`, `**Correction:**` when corrected).

**Fresh discussion.** Fill the template's sections from the conversation, including User Vision, Essential Features, Technical Preferences, Boundaries, Acceptance Criteria, and one `### [Gray Area]` subsection per decision. Leave a section out only when the discussion produced nothing for it, do not invent content to fill the template.

## Design principles

- **One engine.** `/meridian:transit` dispatch and standalone `/meridian:discuss` run the same protocol.
- **Calibrate silently.** Never ask "are you technical?".
- **Orient from the phase, not from templates.** Gray areas come from analysis, not predefined lists.
