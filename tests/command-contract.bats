#!/usr/bin/env bats

load gate_case_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECKER="$REPO_ROOT/scripts/command-contract.sh"
  TEST_ROOT="$(mktemp -d)"
  FIXTURE="$TEST_ROOT/repo"
  mkdir -p "$FIXTURE/commands" "$FIXTURE/config" "$FIXTURE/references" "$FIXTURE/scripts" "$FIXTURE/templates"
  : > "$FIXTURE/config/legacy-identifier-allowlist.txt"
  : > "$FIXTURE/config/gated-tool-prose-allowlist.txt"
  : > "$FIXTURE/scripts/workflow-generator.sh"
  write_valid_command alpha
  write_manifest alpha.md
}

teardown() {
  rm -rf "$TEST_ROOT"
}

write_valid_command() {
  local command_name=$1
  cat > "$FIXTURE/commands/$command_name.md" <<EOF
---
category: core
description: Exercise the command contract checker.
argument-hint: '[target]'
allowed-tools: Read, Bash
disable-model-invocation: true
---

## Context

The main session owns the interaction.

## Guard

STOP when required state is unavailable.

## Steps

Read the requested target.

## Failure and recovery

Report the error and leave state unchanged.

## Output Format

Print a bounded result.

## Next Up

End with Next guidance.
EOF
}

write_manifest() {
  local command_files=("$@")
  python3 - "$FIXTURE/config/command-sections.json" "${command_files[@]}" <<'PY'
import json
import sys

path, *commands = sys.argv[1:]
manifest = {
    "schema_version": 1,
    "contract_patterns": {
        "interaction": r"(?m)^## Context$",
        "guards": r"(?m)^## Guard$",
        "recovery": r"(?m)^## Failure and recovery$",
        "output": r"(?m)^## Output Format$",
        "next_up": r"(?m)^## Next Up$",
    },
    "commands": {
        command: {
            "required_headings": [
                "Context",
                "Guard",
                "Steps",
                "Failure and recovery",
                "Output Format",
                "Next Up",
            ]
        }
        for command in commands
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
}

run_checker() {
  run bash "$CHECKER" --root "$FIXTURE"
}

grant_tool() {
  local tool=$1
  sed -i.bak "s/^allowed-tools: .*\$/&, ${tool}/" "$FIXTURE/commands/alpha.md"
  rm -f "$FIXTURE/commands/alpha.md.bak"
}

append_prose() {
  printf '\n%s\n' "$1" >> "$FIXTURE/commands/alpha.md"
}

run_prose_table() {
  local want_status=$1 grants=$2 label prose fragment tool
  reset_case_failures
  while IFS='|' read -r label prose fragment; do
    [ -n "$label" ] || continue
    write_valid_command alpha
    for tool in $grants; do grant_tool "$tool"; done
    append_prose "$prose"
    run_checker </dev/null
    expect_case "$label" "$want_status" "$fragment"
  done
}

@test "command-contract accepts a complete command set" {
  run_checker

  [ "$status" -eq 0 ]
  [[ "$output" == *'Command contract passed: 1 commands'* ]]
}

@test "command-contract rejects missing fields, empty values, and obsolete names" {
  write_valid_command beta
  write_manifest alpha.md beta.md
  python3 - "$FIXTURE/commands/alpha.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("category: core", "category:")
text = text.replace("argument-hint: '[target]'\n", "")
open(path, "w", encoding="utf-8").write(text)
PY
  python3 - "$FIXTURE/commands/beta.md" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace("---\ncategory:", "---\nname: lbwc:beta\ncategory:")
open(path, "w", encoding="utf-8").write(text)
PY

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'alpha.md: empty frontmatter field: category'* ]]
  [[ "$output" == *'alpha.md: missing frontmatter field: argument-hint'* ]]
  [[ "$output" == *'beta.md: frontmatter must not define name'* ]]
}

@test "command-contract rejects command filenames outside the local slug format" {
  write_valid_command Beta
  write_manifest alpha.md Beta.md

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'Beta.md: command filename must match [a-z0-9][a-z0-9-]*.md'* ]]
}

@test "command-contract rejects unallowlisted legacy identifiers" {
  printf 'Legacy command: /vbw:plan\n' > "$FIXTURE/references/legacy.md"

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'references/legacy.md: forbidden legacy identifier'* ]]
}

@test "command-contract accepts a legacy identifier listed in the allowlist" {
  printf 'Legacy command: /vbw:plan\n' > "$FIXTURE/references/legacy.md"
  printf 'references/legacy.md\n' > "$FIXTURE/config/legacy-identifier-allowlist.txt"

  run_checker

  [ "$status" -eq 0 ]
  [[ "$output" == *'Command contract passed: 1 commands'* ]]
}

@test "command-contract rejects missing referenced paths" {
  append_prose 'Use `scripts/missing-helper.sh` and `references/missing.md`.'

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'alpha.md: missing referenced path: scripts/missing-helper.sh'* ]]
  [[ "$output" == *'alpha.md: missing referenced path: references/missing.md'* ]]
}

@test "command-contract resolves globs and documented placeholders" {
  local role_dir='templates/agent-roles'
  mkdir -p "$FIXTURE/$role_dir"
  printf 'role\n' > "$FIXTURE/$role_dir/dev.md.tpl"
  printf 'profile\n' > "$FIXTURE/references/effort-profile-balanced.md"
  append_prose "Use \`$role_dir/"'*.md.tpl` and `references/effort-profile-{profile}.md`.'

  run_checker

  [ "$status" -eq 0 ]
  [[ "$output" == *'Command contract passed: 1 commands'* ]]
}

@test "command-contract rejects a command missing from the section manifest" {
  write_valid_command beta

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'command is missing from section manifest: beta.md'* ]]
}

@test "command-contract rejects a command lacking a required section and its contract" {
  write_valid_command beta
  write_manifest alpha.md beta.md
  sed -i.bak 's/^## Next Up$/## Later/' "$FIXTURE/commands/beta.md"

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'beta.md: missing required heading: Next Up'* ]]
  [[ "$output" == *'beta.md: missing next_up contract'* ]]
}

@test "command-contract rejects a gated tool named in the body without a grant" {
  run_prose_table 1 "" <<'CASES'
named-in-body|Use native AskUserQuestion to confirm the target before continuing.|alpha.md: names gated tool AskUserQuestion in the body at line
indirect-phrasing|Ask one bounded question via AskUserQuestion for each decision.|alpha.md: names gated tool AskUserQuestion in the body at line
workflow-in-backticks|Call `Workflow` exactly once with scriptPath set.|alpha.md: names gated tool Workflow in the body at line
negated-sentence|Never call the Agent tool directly.|alpha.md: names gated tool Agent in the body at line
agent-call-syntax|Spawn the generated dev by calling `Agent(...)` with its printed subagent_type.|alpha.md: names gated tool Agent in the body at line
task-tool|Spawn the roster by calling the `Task` tool for every teammate.|alpha.md: names gated tool Task in the body at line
negated-instruction|Do not proceed without AskUserQuestion confirmation.|alpha.md: names gated tool AskUserQuestion in the body at line
CASES

  assert_no_case_failures
}

@test "command-contract reports the body line and the allowed-tools line of a gated tool violation" {
  append_prose 'Use native AskUserQuestion to confirm the target before continuing.'
  local body_line allowed_line
  body_line=$(grep -n 'AskUserQuestion' "$FIXTURE/commands/alpha.md" | cut -d: -f1)
  allowed_line=$(grep -n '^allowed-tools:' "$FIXTURE/commands/alpha.md" | cut -d: -f1)

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha.md: names gated tool AskUserQuestion in the body at line $body_line without declaring it in allowed-tools at line $allowed_line"* ]]
}

@test "command-contract accepts a gated tool named in the body once it is declared" {
  grant_tool AskUserQuestion
  append_prose 'Use native AskUserQuestion to confirm the target before continuing.'

  run_checker

  [ "$status" -eq 0 ]
  [[ "$output" == *'Command contract passed: 1 commands'* ]]
}

@test "command-contract accepts a gated tool mention exempted by its allowlisted phrase" {
  printf 'commands/alpha.md:Agent:Agent Teams\n' >> "$FIXTURE/config/gated-tool-prose-allowlist.txt"
  append_prose 'Agent Teams is process-level Claude Code configuration, unrelated to this tool grant.'

  run_checker

  [ "$status" -eq 0 ]
  [[ "$output" == *'Command contract passed: 1 commands'* ]]
}

@test "command-contract still rejects a genuine invocation in a file exempted for an unrelated phrase" {
  printf 'commands/alpha.md:Agent:Agent Teams\n' >> "$FIXTURE/config/gated-tool-prose-allowlist.txt"
  append_prose 'Agent Teams is process-level Claude Code configuration, unrelated to this tool grant.'
  append_prose 'Spawn the generated dev by calling `Agent(...)` with its printed subagent_type.'

  run_checker

  [ "$status" -eq 1 ]
  [[ "$output" == *'alpha.md: names gated tool Agent in the body at line'* ]]
}

@test "command-contract accepts prose that forbids or sanctions workflow authoring" {
  run_prose_table 0 "Workflow AskUserQuestion" <<'CASES'
negated-prohibitions|The main session must never author a workflow script. It must not pass a script parameter to the Workflow tool.|Command contract passed
repeated-negations|Do not author a workflow. Do not write JavaScript. Do not pass a script parameter to the Workflow tool.|Command contract passed
sanctioned-generator|The sanctioned chain is scripts/workflow-generator.sh, whose rendered output is the workflow script. Call Workflow with the returned scriptPath. The shell generator owns every phase and agent call, the main session only supplies the scriptPath.|Command contract passed
CASES

  assert_no_case_failures
}

@test "command-contract rejects prose that instructs the model to author a workflow" {
  run_prose_table 1 "Workflow AskUserQuestion" <<'CASES'
additional-verbs|Create a workflow that runs the team and generate the workflow script yourself.|alpha.md: instructs the model to author a workflow or write JavaScript
infinitive-write|Ignore the generator to write a workflow script yourself.|alpha.md: instructs the model to author a workflow or write JavaScript
infinitive-author|Skip the generator to author a workflow script.|alpha.md: instructs the model to author a workflow or write JavaScript
comma-then-or-after-negation|There is no generator, write a workflow script yourself, or copy one from a sibling command.|alpha.md: instructs the model to author a workflow or write JavaScript
negation-governs-other-verb|Do not wait for the generator, write a workflow script yourself.|alpha.md: instructs the model to author a workflow or write JavaScript
bypass-generator|Bypass the generator and write a workflow script yourself.|alpha.md: instructs the model to author a workflow or write JavaScript
optional-generator|The generator is optional, so author a workflow script directly.|alpha.md: instructs the model to author a workflow or write JavaScript
authoring-with-script-param|Author a workflow script yourself and pass a script parameter to the Workflow tool.|alpha.md: instructs the model to author a workflow or write JavaScript
CASES

  assert_no_case_failures
}

@test "command-contract rejects prose that passes a script parameter to the Workflow tool" {
  run_prose_table 1 "Workflow AskUserQuestion" <<'CASES'
script-as-later-key|Workflow({ name: "team", script: "await log(1)" })|alpha.md: instructs passing a script parameter to the Workflow tool
script-field-prose|Set the script field on the Workflow call to the source you built.|alpha.md: instructs passing a script parameter to the Workflow tool
script-behind-nested-object|Workflow({ args: { a: 1 }, script: "await log(1)" })|alpha.md: instructs passing a script parameter to the Workflow tool
script-without-brace|Workflow(script: "await log(1)")|alpha.md: instructs passing a script parameter to the Workflow tool
authoring-with-script-param|Author a workflow script yourself and pass a script parameter to the Workflow tool.|alpha.md: instructs passing a script parameter to the Workflow tool
CASES

  assert_no_case_failures
}

@test "repository commands satisfy the tracked command contract" {
  run bash "$CHECKER" --root "$REPO_ROOT"

  [ "$status" -eq 0 ]
}
