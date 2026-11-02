---
category: supporting
model: haiku
disable-model-invocation: true
description: Switch between work profiles or create custom ones. Profiles change effort, autonomy, and verification in one go.
argument-hint: "[profile-name | save | delete <name>]"
allowed-tools: Read, Write, Edit, AskUserQuestion
---

# LBWC Profile $ARGUMENTS

## Context

Config:
```
!`cat .lbwc-planning/config.json 2>/dev/null || echo "No config found -- run /lbwc:init first"`
```

@${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md

## Guard

If the .lbwc-planning/ directory does not exist, STOP "Run /lbwc:init first." (check `.lbwc-planning/config.json`)

## Built-in Profiles

| Profile | Effort | Autonomy | Verification | Discovery | Use case |
|---------|--------|----------|--------------|-----------|----------|
| default | balanced | standard | standard | 3-5 questions | Fresh install baseline |
| prototype | fast | confident | quick | 1-2 quick | Rapid iteration |
| production | thorough | cautious | deep | 5-8 thorough | Production code |
| yolo | turbo | pure-vibe | skip | skip | No guardrails |

## Behavior

### List and switch with no arguments

1. Read config.json for `active_profile` (default: "default") + `custom_profiles`. Display table with * on active. If active_profile is "custom": show "Active: custom (modified from {last_profile})".
2. AskUserQuestion "Which profile?" Offer all profiles + "Create new profile" as options. Mark current "(active)".
3. Apply by updating effort/autonomy/verification_tier in config.json and setting active_profile. Display changed values with ➜. If already matching, show "✓ Already on {name}". If "Create new profile", go to Save flow.

### `save` creates a custom profile

**S1.** AskUserQuestion: "From current settings" (use current values) | "From scratch" (pick each)
**S2.** If "From scratch", ask 3 AskUserQuestions in this order.

Ask for effort (thorough | balanced | fast | turbo), then autonomy (cautious | standard | confident | pure-vibe). Finally ask for verification (quick | standard | deep | skip).

**S3.** AskUserQuestion for a name, suggest 2-3 contextual names and allow the user to type their own.
**S4.** Validate with no built-in clash, no spaces (suggest hyphens), and 1-30 chars. Add to `custom_profiles` in config.json. Ask "Switch to {name} now?" Apply if yes.

### Direct name via `profile <name>`

If $ARGUMENTS matches a profile, apply immediately (no listing). If unknown, show "⚠ Unknown profile: {name}" + list available.

### `delete <name>`

For a built-in profile, show "⚠ Cannot delete built-in profile." If not found, show "⚠ Profile not found." Otherwise, remove from custom_profiles. If active, reset to "default".

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/lbwc-brand-essentials.md , single-line box, ✓ success, ⚠ errors, ➜ transitions, no ANSI.

## Next Up

After validation, show `/lbwc:profile` to review the active profile and stop.
