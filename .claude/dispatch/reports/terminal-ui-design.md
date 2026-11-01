# Terminal UI design

This spec covers the three surfaces a Meridian user reads in Claude Code, which are the statusline, the per-step feedback card, and the status card. Task 17 implements the two cards, and Task 13b implements the `visual_format` switch. The owner approved the compact table card on 2026-11-01.

## Palette

The colors come from the hand-illustrated brand board. The statusline uses 24-bit ANSI colors when the terminal reports truecolor support and the 256-color nearest match otherwise. When the user sets `NO_COLOR`, it prints plain text.

| Role | Board source | Hex |
| --- | --- | --- |
| Brand | Deep teal of the mark | `#1F5F66` |
| Active | Turquoise of the orbit | `#3FB8AF` |
| Info | Sky blue of the explore pill | `#3A9AD9` |
| Star and attention | Amber of the star | `#F2B233` |
| Warning | Orange of the trace pill | `#EE8434` |
| Failure | Brick red, darker than the warning orange | `#C8553D` |
| Muted | Grey teal for labels | `#7A9497` |

## Glyph table

One shared table in `scripts/lib/` holds both glyph sets, and `visual_format` picks the set.

| Meaning | `unicode` | `ascii` |
| --- | --- | --- |
| Brand mark | `✦` | `*` |
| Done | `✔` | `[ok]` |
| Running | `◐` | `[..]` |
| Needs you | `?` | `[?]` |
| Failed | `✖` | `[x]` |
| Not started | `○` | `-` |
| Separator | ` · ` | ` | ` |
| Bar filled and empty | `▮` and `▯` | `#` and `-` |
| Next step | `→` | `->` |

## Statusline

The statusline keeps every field it shows today in four lines. Each tmux and diagnostic field moves into line 3 and appears only when it has something to say, so the quiet case stays short.

```text
L1  ✦ meridian · sonnet high · lbwc@refactor/meridian-2.0 ● · 2h 14m
L2  ▮▮▮▮▯▯▯▯▯▯ 42% context · in 1.2M · out 88k · cache 900k/40k · $3.10 · +120 −40
L3  Flow phase 03 build · task 2/5 · pair engineer+critic · QA ◐ · UAT ○ · tmux 3 agents (2 run, 1 idle)
L4  Quota 5h ▮▮▮▯▯ 38% resets 14:00 · 7d ▮▯▯▯▯ 12% resets Fri
```

The same lines with `visual_format: ascii` read as follows.

```text
L1  * meridian | sonnet high | lbwc@refactor/meridian-2.0 * | 2h 14m
L2  [####------] 42% context | in 1.2M | out 88k | cache 900k/40k | $3.10 | +120 -40
L3  Flow phase 03 build | task 2/5 | pair engineer+critic | QA [..] | UAT - | tmux 3 agents (2 run, 1 idle)
L4  Quota 5h [###--] 38% resets 14:00 | 7d [#----] 12% resets Fri
```

1. Line 1 colors the mark brand teal, the model sky blue, and the dirty dot amber.
2. Line 2 colors the bar turquoise up to 70 percent, amber up to 85 percent, and orange above that, the same thresholds the caveman level uses.
3. Line 3 shows telemetry only when it is not healthy, and it shows a tmux failure count in brick red with the diagnostics text.
4. Line 4 follows `statusline_hide_limits` and `statusline_hide_limits_for_api_key`.
5. The collapse switch for tmux agent panes folds lines 1 to 3 into one line that starts with the brand mark.

## Feedback card

Every step ends with this card in chat. Claude Code renders it as markdown, so the table aligns in any width. The table header names the result, the stage, and the scope, because a markdown table needs a header row and an empty one renders as a blank stripe. The table holds facts only, and the last two lines tell the human what happens next and what they must approve.

```markdown
| ✔ Build | phase 03, plan 02 done |
| --- | --- |
| Changed | 4 files |
| Proof | 38 tests pass, rerun by the main session |
| Agents | engineer and critic, both used |
| Open | none |

**Next.** QA for phase 03.

**You approve.** Start QA? (yes or no)
```

Each closing line is its own paragraph, because markdown joins lines without a blank line between them into one paragraph.

1. The header glyph shows the result. `✔` means done, `◐` means running, `?` means the step waits for the human, and `✖` means it failed.
2. The Proof row always says who ran the proof. A worker claim alone never fills this row.
3. When a step fails, the table adds a Cause row and a Fix row, and the approval line offers the fix.
4. When nothing needs approval, the last line reads `**You approve.** Nothing, Meridian continues.`

## Status card

`/meridian:status` prints one card that a human reads in five seconds.

```markdown
| ✦ Meridian | lbwc, milestone 2.0 | |
| --- | --- | --- |
| 01 Setup | ✔ done | ▮▮▮▮▮▮▮▮▮▮ 100% |
| 02 Guards | ✔ done | ▮▮▮▮▮▮▮▮▮▮ 100% |
| 03 Build loop | ◐ build | ▮▮▮▮▯▯▯▯▯▯ 40% |
| 04 Handover | ○ next | ▯▯▯▯▯▯▯▯▯▯ 0% |

**Now.** Plan 02 of phase 03, with an engineer and a critic at work.

**Logbook.** At 10:42 the critic approved task 2, and task 3 comes next.

**Next.** QA for phase 03 after the last plan.

**Needs you.** Nothing right now.
```

## Rules for all three surfaces

1. Every surface ends with what happens next.
2. No surface prints a raw path, a stack trace, or a token count the human did not ask for, except the statusline token fields that exist today.
3. Color never carries meaning alone, so each state also has a glyph or a word.
4. The `ascii` set renders in any terminal font, and both sets produce the same line count.
