---
category: supporting
model: sonnet
disable-model-invocation: true
description: Collect redacted local diagnostics, classify a bug or feature, and prepare a GitHub issue.
argument-hint: "[problem description]"
allowed-tools: Read, Bash, Glob, Grep, AskUserQuestion, mcp__plugin_gitkraken_gitkraken__issues_create
---

# MERIDIAN Report $ARGUMENTS

## Context

Plugin root:

```bash
!`SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n%s\n" "${CLAUDE_PLUGIN_ROOT:-}" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"; [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }; L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "MERIDIAN: plugin root unavailable" >&2; exit 1; }; bash "$R"`
```

Store the output as `{plugin-root}`. Read its VERSION, the local Claude Code version, operating system, MERIDIAN hook health, project phase detector output, and project configuration validation status.

@${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md

## Parse Arguments

Treat all of `$ARGUMENTS` as the optional problem description. An empty description defaults to a bug report and uses `Not provided` for human-authored fields.

## Guard

Diagnostics are read-only and local. Redact the home path, user name, credential-looking environment values, and all token or key values. Do not include prompts, transcripts, source file contents, raw environment output, Git remotes with embedded credentials, or planning artifacts beyond status fields.

Creating a GitHub issue mutates shared third-party state. Collect and preview the exact title, body, repository, and label first. Then ask one bounded confirmation. A dismissed or cancelled question files nothing.

## Scope

This command may collect redacted diagnostics, write session-scoped temporary files with mode 600, and create one issue in `michaelheichler/meridian` after immediate confirmation. It does not change project source, planning state, Git history, plugin configuration, or user credentials.

## Steps

1. **Collect redacted diagnostics.** Use one trusted Bash call with `umask 077`. Write `/tmp/meridian-diag-report-${CLAUDE_SESSION_ID:-default}.txt` containing only:

   Environment:
   - MERIDIAN and Claude Code versions
   - OS name and architecture
   - plugin-root resolution and hooks JSON parse status

   Project validation:
   - `meridian-config.sh validate` and `meridian-model validate` results when initialized
   - `phase-detect.sh` status fields, excluding artifact contents

   Optional integration health:
   - `rtk-manager.sh doctor-json` compatibility summary
   - `doctor-cleanup.sh scan` finding counts, not process command lines

   Replace the home directory with `~` and the local user name with `<user>`. If any collector fails, include its exit status and continue. Never use failure as permission to collect broader data.

2. **Display the report.** Show the optional problem description, followed by the exact redacted diagnostic file in a fenced block. Do not display the temp-file path as issue content.

3. **Classify.** Use `bug` for broken, unexpected, crashing, regressed, or ambiguous behavior. Use `enhancement` for a requested new capability or intentional workflow change.

4. **Compose the preview.** Derive a concise title of about ten words. Compose the literal body structure matching the issue fields below. Keep every bold header on its own line, put content on the following line, and leave a blank line between sections. Source diagnostics from the temp file, not memory.

   **Bug classification**

   ```markdown
   **Command**
   {the /meridian:* command that triggered the issue, or "Not specified"}

   **What happened**
   {problem description from $ARGUMENTS, or "Not provided, please edit this section"}

   **What you expected**
   {inferred expected behavior, or "Not provided, please edit this section"}

   **Steps to reproduce**
   {reproduction steps, or "Not provided, please edit this section"}

   **Environment**
   - Claude Code version: {from diagnostics}
   - OS: {from diagnostics}
   - Plugin install method: {from diagnostics}
   - Model: {from diagnostics or "Not specified"}

   **Additional context**
   {diagnostic report in a fenced block, sourced from the temp file}
   ```

   **Enhancement classification**

   ```markdown
   **Problem**
   {problem description from $ARGUMENTS, or "Not provided, please edit this section"}

   **Proposed solution**
   {inferred proposed solution, or "Not provided, please edit this section"}

   **Alternatives considered**
   {alternatives from the description, or "Not provided, please edit this section"}

   **Additional context**
   {diagnostic report in a fenced block, sourced from the temp file}
   ```

5. **Confirm the exact external mutation.** Ask one question:
   - `File issue`: Create the shown issue in the shown repository with the shown label.
   - `Copy only`: Display the final title and body without filing.
   - `Cancel`: Delete the temporary diagnostics and stop.

6. **File only after confirmation.** Use this ordered fallback chain and stop at the first successful method. The confirmed repository (`michaelheichler/meridian`), title, label, and body must not change after confirmation.

   **Method 1, `gh` CLI (if installed and authenticated):** Check `gh auth status 2>/dev/null`. If it succeeds, create a mode-600 body file and call `gh issue create --repo michaelheichler/meridian --title <title> --label <bug|enhancement> --body-file <file>`. The body file must contain the literal template sections above and the complete diagnostic report from the temp file under `**Additional context**`. Delete both temporary files after success or failure.

   **Method 2, GitHub MCP equivalent (if available):** If `gh` is unavailable or unauthenticated, check whether `mcp__plugin_gitkraken_gitkraken__issues_create` is available in the tool list. If it is, re-derive `DIAG_FILE="/tmp/meridian-diag-report-${CLAUDE_SESSION_ID:-default}.txt"`, read its diagnostics, and compose the complete confirmed body with the same literal template and fenced `**Additional context**`. Call the tool with `provider: github`, `repository_organization: michaelheichler`, `repository_name: meridian`, the confirmed `title`, the complete `body`, `labels: ["bug"]` or `["enhancement"]`, and `assignees: []`. Leave Jira-only `issue_type` empty. Delete the diagnostic temp file after the MCP call succeeds or fails. Never invoke an unavailable MCP tool or silently replace this method with a different mutation.

   **Method 3, manual last resort:** If neither automatic method is available or either method fails, re-derive `DIAG_FILE="/tmp/meridian-diag-report-${CLAUDE_SESSION_ID:-default}.txt"`, read the diagnostics into the confirmed body, delete the temp file, and display the title, body, and `https://github.com/michaelheichler/meridian/issues/new?template=bug_report.md` for bugs or `https://github.com/michaelheichler/meridian/issues/new?template=feature_request.md` for enhancements. Do not install software or start interactive login automatically. If the user wants interactive authentication in this session, tell them to run `! gh auth login --web` and re-run `/meridian:report`.

## Failure and recovery

A missing root resolver, unreadable diagnostic file, failed redaction boundary, changed payload after confirmation, or failed issue creation stops the command. State whether you created no issue or whether the successful filing method returned a URL. Never claim success without the URL from `gh issue create` or the GitHub MCP result.

## Output Format

Show classification, redacted diagnostics, exact issue preview, confirmation result, and either the created issue URL or the MCP/manual fallback body. Do not print credentials or temporary file paths after cleanup.

## Next Up

After a created issue, show its URL and stop. After Copy only, show the manual issue URL and stop. After an MCP or manual fallback, show the returned issue URL when available or the manual issue URL and stop. After Cancel, report `Issue not created` and stop.
