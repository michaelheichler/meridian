---
name: Meridian
description: A hand-illustrated explorer world that reaches GitHub through raster art and the terminal through glyphs and ANSI color.
colors:
  brand-teal: "#1F5F66"
  active-turquoise: "#3FB8AF"
  info-sky: "#3A9AD9"
  star-amber: "#F2B233"
  warning-orange: "#EE8434"
  failure-brick: "#C8553D"
  muted-grey-teal: "#7A9497"
components:
  readme-hero:
    width: "760px"
  readme-pill-row:
    width: "640px"
  readme-loop-icon:
    size: "40px"
  readme-feature-icon:
    size: "32px"
  statusline-mark:
    textColor: "{colors.active-turquoise}"
  statusline-model:
    textColor: "{colors.info-sky}"
  statusline-separator:
    textColor: "{colors.muted-grey-teal}"
  statusline-dirty:
    textColor: "{colors.star-amber}"
  statusline-bar-filled:
    textColor: "{colors.active-turquoise}"
  statusline-bar-filled-high:
    textColor: "{colors.star-amber}"
  statusline-bar-filled-critical:
    textColor: "{colors.warning-orange}"
  statusline-bar-empty:
    textColor: "{colors.muted-grey-teal}"
  statusline-running:
    textColor: "{colors.star-amber}"
  statusline-failure:
    textColor: "{colors.failure-brick}"
---

# Meridian Design System

## Overview

**Creative North Star: "The Explorer Logbook"**

Meridian looks like a field journal that an explorer keeps by hand. The owner drew every brand element on one board at `assets/brand/meridian-brand-board.png`. The board holds the mark (orbit, star, and open book) and a rounded wordmark. It also holds eight icons, five capability pills, and an app icon tile. Soft painted texture, warm amber light, and calm teal water set the mood. The art carries all the warmth, so the words around it stay plain and short.

The system lives on two surfaces that own no stylesheet. The GitHub README renders markdown without CSS, so the brand reaches it only through sliced raster art. The terminal surfaces in Claude Code speak through glyphs, plain markdown tables, and ANSI color in the statusline. Both surfaces end every view with the next step.

Density stays low. One idea fills each table row, one sentence fills each cell, and short paragraphs separate the tables.

**Key Characteristics.**
- Hand-illustrated raster art supplies every brand color on GitHub.
- Light and dark README variants switch through a `<picture>` element.
- Terminal state reads from a glyph or a word first, and color only reinforces it.
- Two glyph sets, `unicode` and `ascii`, produce the same line count.
- Every surface closes with what happens next and what the human approves.

## Colors

A painted palette of deep teal water, turquoise orbit, sky blue, and warm amber starlight, with orange and brick for trouble. The README carries these colors inside the art. The statusline carries them as 24-bit ANSI color, with the nearest 256-color match as a fallback, and prints plain text under `NO_COLOR`.

### Primary
- **Deep Harbor Teal** (brand-teal). The disc of the mark, the wordmark, and the app icon tile. In the terminal mockup it draws the frame of the statusline block. The mark glyph on a dark terminal takes Orbit Turquoise instead, because deep teal on a near-black background falls to about 2.6 to 1 contrast.

### Secondary
- **Orbit Turquoise** (active-turquoise). The brand mark glyph and wordmark in the statusline, filled bar cells below 70 percent, and added-line counts. It means healthy or in progress.
- **Explore Sky** (info-sky). The model name in the statusline and the books and explore pills in the art. It means neutral information.

### Tertiary
- **Starlight Amber** (star-amber). The star in the mark, the dirty-worktree dot, the running glyph, and bar cells from 70 to 85 percent. It asks for attention without alarm.
- **Book Page Orange** (warning-orange). The right page of the book and the trace pill. In the terminal it marks bar cells above 85 percent and removed-line counts.
- **Brick** (failure-brick). Failure only, such as a tmux failure count. It sits darker than the orange so the two warm states never blur.

### Neutral
- **Grey Teal** (muted-grey-teal). Separators, empty bar cells, labels, and the not-started glyph. Body text uses the default terminal or GitHub foreground, which Meridian never overrides.

### Named Rules
**The Art Carries Color Rule.** On GitHub, brand color appears only inside the owner's raster art. Markdown text, tables, and code blocks keep the default GitHub theme in both light and dark mode.

**The Glyph First Rule.** Color never carries meaning alone. Every colored state in the statusline also has a glyph or a word, and the markdown cards carry no color at all.

## Typography

**Display Font.** None set in type. The wordmark and the tagline graphic live inside the hero raster as rounded, friendly letterforms.
**Body Font.** The GitHub default sans stack on the README and the user's terminal font in Claude Code.
**Label/Mono Font.** The GitHub or terminal monospace for commands, the statusline, and code blocks.

**Character.** Meridian owns no font file. Its voice comes from the hand-lettered wordmark in the art and from plain, short sentences everywhere else.

### Hierarchy
- **Display** (raster). The hero image replaces a top-level heading. No `#` heading appears in the README.
- **Headline** (markdown `##`). Section names in sentence case, such as "The loop", "Features", and "Quick start".
- **Title** (bold table header). The first row of every table names its columns or, on a card, the result.
- **Body** (default paragraph). One to three sentences per paragraph, and one full sentence per table cell.
- **Label** (bold lead-in with a period). Card closing lines open with a bold word and a period, such as "**Next.**" or "**You approve.**", followed by the fact. Feature rows use a bold area name under the icon.

### Named Rules
**The Lettered Name Rule.** The wordmark appears only as the owner's artwork. No surface sets "meridian" in a display font as a substitute.

## Layout

The README follows one centered column at the GitHub content width. The hero sits centered at 760px wide, and the capability pill row sits centered at 640px under the opening paragraph. The loop table and the feature table put a centered icon column (`:---:` alignment) on the left. A left-aligned sentence column sits on the right. Loop icons render at 40px above the step numeral, and feature icons render at 32px above the bold area name. The commands table uses two left-aligned columns with the command in inline code.

The statusline holds four lines at most. Line 3 hides each tmux and diagnostic field that has nothing to say, so the quiet case stays short. For tmux agent panes, a collapse switch folds lines 1 to 3 into one line.

The cards keep a compact two- or three-column table, then one paragraph per closing line.

**The Separate Lines Rule.** Each closing line of a card stands as its own paragraph with a blank line before it. Markdown joins adjacent lines into one paragraph.

## Elevation & Depth

All surfaces sit flat. The README and the cards have no shadows and no layered panels. Depth exists only inside the painted art, where soft texture and highlights give the mark and pills a gentle, hand-drawn volume. The flat markdown around the art lets that volume stand out.

## Shapes

The art supplies the only shapes. Capability pills are full capsules, and the app icon is a rounded square tile. Icons sit in soft rounded or circular silhouettes such as the compass ring and the shield. Markdown tables keep the default square GitHub grid. No surface draws its own border or radius.

## Components

### Hero
The centered hero image holds the mark, the wordmark, and the tagline graphic at 760px wide. A `<picture>` element serves `assets/meridian-hero.png` by default and `assets/meridian-hero-dark.png` to readers who prefer dark mode. The alt text reads the full mark and tagline. The tagline on the board remains a draft, so a tagline change means a new slice from the board.

### Capability Pill Row
The single raster `assets/pills/row.png` shows the five capsules subagents, books, guard, trace, and explore, with one alt text that names all five. The separate pill slices stay available for other surfaces.

### Icon Table
The loop table and the feature table pair one board icon with one full sentence per row. Icons carry empty alt text because the step numeral or the bold area name beside them already says what they mean. Each of the eight board icons maps to one feature area.

### Feedback Card
Every step ends with this card in chat. The header row names the result glyph, the stage, and the scope. A markdown table needs a real header row, and an empty one renders as a blank stripe. The body rows hold facts only. The Proof row always names who ran the proof. A failed step adds Cause and Fix rows. Two closing paragraphs follow, "**Next.**" and "**You approve.**". When nothing needs approval, the last line says so and states that Meridian continues.

### Status Card
A three-column table opens with the brand mark and the project in the header row. Each phase row shows the phase, a state glyph with a word, and a ten-cell bar with a percentage. Four closing paragraphs follow, "**Now.**", "**Logbook.**", "**Next.**", and "**Needs you.**".

### Statusline
Four lines of fields with a separator between them, colored as the frontmatter assigns. The context bar has ten cells and changes color at 70 and 85 percent, the same thresholds the caveman level uses.

### Glyph Set
One shared table in `scripts/lib/` holds both sets, and `visual_format` picks one.

| Meaning | `unicode` | `ascii` |
| --- | --- | --- |
| Brand mark | `✦` | `*` |
| Done | `✔` | `[ok]` |
| Running | `◐` | `[..]` |
| Needs you | `?` | `[?]` |
| Failed | `✖` | `[x]` |
| Not started | `○` | `-` |
| Separator | ` · ` | ` \| ` |
| Bar filled and empty | `▮` and `▯` | `#` and `-` |
| Next step | `→` | `->` |

**The Same Lines Rule.** The `ascii` set renders in any terminal font and produces exactly the same line count as the `unicode` set.

## Do's and Don'ts

### Do:
- **Do** bring brand color to GitHub only through slices of `assets/brand/meridian-brand-board.png`.
- **Do** ship a light and a dark variant for any art that sits on the page background, and switch them with `<picture>`.
- **Do** give every table a real header row. Cards put the status in that header row.
- **Do** write each closing card line as its own paragraph.
- **Do** pair every colored state with a glyph or a word.
- **Do** keep the `unicode` and `ascii` glyph sets at the same line count.
- **Do** give every image alt text. Where the adjacent text already names an icon, leave its alt text empty.

### Don't:
- **Do not** add shields.io badges or emoji to stand in for brand color.
- **Do not** set the wordmark in a font. Use the art.
- **Do not** let color alone signal a state in the statusline or anywhere else.
- **Do not** leave a card header row empty.
- **Do not** paint the mark glyph Deep Harbor Teal on a dark terminal.
