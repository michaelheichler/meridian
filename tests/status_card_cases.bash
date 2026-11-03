card_edit() {
  jq "$1" result > updated
  mv updated result
}

card_render() {
  run env LC_ALL=C bash "$SCRIPTS_DIR/status-card.sh" phase result
}

card_check() {
  printf '%s\n' "$output" > card-output
  python3 -c "$1" card-output
}

card_status() {
  local state=$1 glyph=$2 wanted=$3
  card_edit ".status=\"$state\""
  card_render
  [ "$status" -eq "$wanted" ]
  local displayed_state=${state//_/\\_}
  [[ "${lines[0]}" == *"$glyph Implement parser"*'phase build, plan Parser plan, '*"$displayed_state"* ]]
  [[ "$output" == *'| Product | Sample product |'* ]]
  [[ "$output" == *'| Phase | build |'* ]]
  [[ "$output" == *'| Step | Implement parser |'* ]]
  [[ "$output" == *'| Plan | Parser plan |'* ]]
  [[ "$output" == *'| Done files | 2 |'* ]]
  [[ "$output" == *'| Done | 12 lines added |'* ]]
  [[ "$output" == *'| Done | 3 lines deleted |'* ]]
  [[ "$output" == *'| Tests | Parser checks pass |'* ]]
  [[ "$output" == *'exit 0, main session re-ran, check parser'* ]]
  [[ "$output" == *$'\n\n**Next.** /sample:qa, Review parser\n\n**You approve.** '* ]]
}

card_done() {
  card_status done '✔' 0
  [[ "$output" != *'| Cause |'* ]]
  [[ "$output" != *'| Detail |'* ]]
  [[ "$output" != *'| Fix |'* ]]
}
card_running() { card_status running '◐' 0; }
card_needs_you() { card_status needs_you '?' 0; }
card_failed() {
  card_status failed '✖' 1
  [[ "$output" == *'| Cause | hidden cause |'* ]]
  [[ "$output" == *'| Detail | hidden detail |'* ]]
  [[ "$output" == *'| Fix | hidden fix |'* ]]
}
card_ascii_done() { card_ascii done '✔' '\[ok\]' 0; }
card_ascii_running() { card_ascii running '◐' '\[..\]' 0; }
card_ascii_needs_you() { card_ascii needs_you '?' '\[?\]' 0; }
card_ascii_failed() { card_ascii failed '✖' '\[x\]' 1; }
card_ascii() {
  local state=$1 unicode=$2 ascii=$3 wanted=$4
  card_edit ".status=\"$state\""
  card_render
  printf '%s\n' "$output" > unicode-output
  printf '{"visual_format":"ascii"}\n' > "$LBWC_PLANNING_DIR/config.json"
  card_render
  [ "$status" -eq "$wanted" ]
  [[ "${lines[0]}" == *"$ascii Implement parser"* ]]
  printf '%s\n' "$output" > card-output
  python3 -c 'import pathlib,sys
text=pathlib.Path("card-output").read_text()
original=pathlib.Path("unicode-output").read_text()
assert len(text.splitlines()) == len(original.splitlines())
assert text.replace(sys.argv[1],sys.argv[2]) == original' "$ascii" "$unicode"
}
card_questions() {
  card_edit '.status="needs_you" | .open_questions=[range(200) | "question \(.)"]'
  card_render
  [ "$status" -eq 0 ]
  card_check 'import pathlib,sys
rows=pathlib.Path(sys.argv[1]).read_text().splitlines()
actual=[row for row in rows if row.startswith("| Ask |")]
expected=["| Ask | question %d |" % n for n in range(200)]
assert actual == expected'
}
card_clipping() {
  card_edit '.product=("é" * 301) | .commands[0].command=("x" * 500) | .next={command:("c" * 301),step:("s" * 301)}'
  card_render
  [ "$status" -eq 0 ]
  card_check 'import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_bytes().decode("utf-8",errors="strict")
assert "| Product | " + "é" * 300 + "... |" in text
assert "exit 0, main session re-ran, " in text
assert "\n\n**Next.** " + "c" * 300 + "..., " + "s" * 300 + "...\n\n**You approve.** " in text'
}
card_rendered_contracts() {
  local role
  reset_case_failures
  for role in architect coding-dijkstra-critic coding-dijkstra debugger deviq docs lead-critic lead python-critic python-engineer qa-author qa scout test-dev ux-oracle web-code-critic web-engineer; do
    run card_rendered_contract "$role"
    expect_case "$role" 0
  done
  assert_no_case_failures
}
card_rendered_contract() {
  bash "$SCRIPTS_DIR/render-agent-template.sh" "$1" name=sample model=sample description='Review parser' job='Inspect parser' initialPrompt='Custom parser context' > rendered
  python3 -c 'import pathlib
text=pathlib.Path("rendered").read_text()
front,body=text.split("\n---\n",1)
pointer="$CLAUDE_PLUGIN_ROOT/references/handoff-schemas.md"
assert front.count(pointer)==1
assert front.count("status, changed_files, commands (command, exit_code), and open_questions")==1
assert front.count("Custom parser context")==1
assert body.count(pointer)==1
contract=body.rsplit("## Final result",1)[1]
assert contract.count("`status`, `changed_files`, `commands` (`command`, `exit_code`), and `open_questions`")==1'
}
card_qa_handoff() {
  bash "$SCRIPTS_DIR/render-agent-template.sh" qa name=sample model=sample description='Review parser' job='Inspect parser' > rendered
  mkdir verification
  python3 -c 'import pathlib
text=pathlib.Path("rendered").read_text()
spec=next(line for line in text.splitlines() if line.startswith("- `## Must-Have Checks`"))
header=spec.split("`")[-2]
report="## Must-Have Checks\n| "+header+" |\n| 1 | MH-1 | Parser handles empty input | PASS | deterministic check |\n"
pathlib.Path("verification/VERIFICATION.md").write_text(report)'
  run bash "$SCRIPTS_DIR/extract-verified-items.sh" "$PWD/verification"
  [ "$status" -eq 0 ]
  [[ "$output" == *'PASS MH-1: Parser handles empty input'* ]]
}
card_rejected() {
  card_edit "$1"
  card_render
  [ "$status" -eq 1 ]
  [[ "$output" == *'| Cause |'* ]]
  [[ "$output" == *'**You approve.**'* ]]
}
card_malformed() { printf '{' > result; card_render; [ "$status" -eq 1 ]; }
card_multiple() { printf '{}{}' > result; card_render; [ "$status" -eq 1 ]; }
card_wrong_types() {
  local filter
  reset_case_failures
  for filter in '.changed_files="parser.sh"' '.changed_files=[null]' '.commands={}' '.commands=["check"]' '.commands[0].command=42' '.open_questions=[false]' '.product=null' '.step=[]' '.plan=42' '.tests=false' '.lines_changed=[]' '.next=[]' '.next.command=null' '.next.step=""' '.details={}' '.cause=42' '.fix=false' '.status="unknown"'; do
    run card_rejected "$filter"
    expect_case "$filter" 0
  done
  assert_no_case_failures
}
card_missing_main() { card_rejected 'del(.commands[0].main_session)'; }
card_null_main() { card_rejected '.commands[0].main_session=null'; }
card_string_main() { card_rejected '.commands[0].main_session="true"'; }
card_string_exit() { card_rejected '.commands[0].exit_code="0"'; }
card_negative_exit() { card_rejected '.commands[0].exit_code=-1'; }
card_fraction_exit() { card_rejected '.commands[0].exit_code=0.5'; }
card_large_exit() { card_rejected '.commands[0].exit_code=256'; }
card_float_lines() { card_rejected '.lines_changed.added=1.5'; }
card_no_commands() { card_rejected '.commands=[]'; }
card_open_done() { card_rejected '.open_questions=["Resolve parser ambiguity"]'; }
card_nonzero() {
  card_edit '.status="running" | .commands[0].exit_code=7'
  card_render
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == *'failed'* ]]
  [[ "$output" == *'exit 7, main session re-ran'* ]]
}
card_missing_phase() { printf 'phase_detect_complete=true\n' > phase; card_render; [ "$status" -eq 1 ]; }
card_empty_phase() { printf 'next_phase=\nphase_detect_complete=true\n' > phase; card_render; [ "$status" -eq 1 ]; }
card_phase_error() { printf 'next_phase=build\nphase_detect_complete=true\nphase_detect_error=true\n' > phase; card_render; [ "$status" -eq 1 ]; }
card_missing_args() { run bash "$SCRIPTS_DIR/status-card.sh"; [ "$status" -eq 1 ]; }
card_unreadable() { rm result; card_render; [ "$status" -eq 1 ]; }
card_no_jq() {
  mkdir bin
  ln -s /usr/bin/dirname bin/dirname
  run env PATH="$PWD/bin" /bin/bash "$SCRIPTS_DIR/status-card.sh" phase result
  [ "$status" -eq 1 ]
  [[ "$output" == *'| Cause |'* ]]
}
card_controls() {
  card_edit 'walk(if type=="string" then .+"\u001b\u0007\u0000\u007f" else . end) | .status="failed"'
  card_render
  [ "$status" -eq 1 ]
  card_check 'import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_bytes()
assert not set(text).intersection({0,7,27,127})
assert b"Sample product     |" in text'
}
card_phase_controls() {
  printf 'next_phase=build\033\007\000\177\nphase_detect_complete=true\n' > phase
  card_render
  [ "$status" -eq 0 ]
  card_check 'import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_bytes()
assert not set(text).intersection({0,7,27,127})
assert b"| Phase | build     |" in text'
}
card_markup() {
  card_edit '.product="[link](https://example.invalid) <b> `cmd` | extra\n| fake | row |"'
  card_render
  [ "$status" -eq 0 ]
  card_check 'import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
assert r"\[link\](https://example.invalid) \<b\> \`cmd\` \| extra \| fake \| row \|" in text
assert "\n| fake" not in text
assert len([row for row in text.splitlines() if row.startswith("| Product |")]) == 1'
}
card_command_injection() {
  card_edit '.commands[0].command="$(touch INJECTED)"'
  card_render
  [ "$status" -eq 0 ]
  [ ! -e INJECTED ]
  [[ "$output" == *'$(touch INJECTED)'* ]]
}
