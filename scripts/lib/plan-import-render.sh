# Plain assignments, because bash 3.2 has no declare -g.
PLAN_DESTINATION=""
MD_H1='#' MD_H2='##' MD_H3='###'

write_text() {
  local path="$1" value="$2" temporary
  mkdir -p "$(dirname "$path")"
  temporary="$(dirname "$path")/.$(basename "$path").tmp.$$"
  printf '%s\n' "$value" > "$temporary"
  mv -f "$temporary" "$path"
}

import_project_name() {
  jq -r '.project.name // "Imported project"' "$1"
}

render_config() {
  local output="$1" defaults validated
  defaults=$("$SCRIPT_DIR/meridian-config.sh" default-config 2>/dev/null) \
    || import_fail 'could not build canonical configuration defaults'
  validated=$("$SCRIPT_DIR/meridian-config.sh" validate-config-json <<< "$defaults" 2>/dev/null) \
    || import_fail 'canonical configuration defaults failed repository validation'
  write_text "$output/config.json" "$validated"
}

project_document() {
  local name="$1" description="$2"
  cat <<EOF
$MD_H1 $name

$description

**Core value:** Unknown; set during the first /meridian:transit session.

$MD_H2 Requirements

$MD_H3 Validated
_None yet._

$MD_H3 Active
- [ ] Review imported requirements in REQUIREMENTS.md.

$MD_H3 Out of Scope
- None recorded during import.

$MD_H2 Constraints
- **Imported state**: canonical artifacts below were staged from an external source and promoted explicitly.

$MD_H2 Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Imported external plan | Source digest recorded under .meridian/imports/ | Pending review |
EOF
}

render_project() {
  local ir="$1" output="$2" name description
  name=$(import_project_name "$ir")
  description=$(jq -r '.project.description // "Imported from an external plan source. See .meridian/imports/ for provenance."' "$ir")
  write_text "$output/PROJECT.md" "$(project_document "$name" "$description")"
}

requirement_lines() {
  local ir="$1" lines='' requirement mark req_id req_text
  while IFS= read -r requirement; do
    if [ "$(jq -r '.status // empty' <<< "$requirement")" = complete ]; then mark=x; else mark=' '; fi
    req_id=$(jq -r '.id' <<< "$requirement")
    req_text=$(jq -r '.text' <<< "$requirement")
    lines+="- [$mark] **$req_id**: $req_text"$'\n'
  done < <(jq -c '.requirements[]' "$ir")
  [ -n "$lines" ] || lines='- [ ] **REQ-00**: No requirements were present in the imported source.'
  printf '%s' "${lines%$'\n'}"
}

requirements_document() {
  local name="$1" lines="$2"
  cat <<EOF
$MD_H1 $name Requirements

Defined: $(date -u +%Y-%m-%d) | Core value: unknown until the first /meridian:transit session

$MD_H2 v1 Requirements

$MD_H3 Imported
$lines

$MD_H2 Out of Scope

- None recorded during import
EOF
}

render_requirements() {
  local ir="$1" output="$2" name lines
  name=$(import_project_name "$ir")
  lines=$(requirement_lines "$ir")
  write_text "$output/REQUIREMENTS.md" "$(requirements_document "$name" "$lines")"
}

roadmap_phase_lines() {
  local phase="$1" slug status goal
  slug=$(jq -r '.slug' <<< "$phase")
  status=$(jq -r '.status // "pending"' <<< "$phase")
  goal=$(jq -r 'if (.plans | length) > 0 then .plans[0].title // "Imported phase" else "Imported phase" end' <<< "$phase")
  if [ "$(jq -r '.phase_present' <<< "$phase")" = true ]; then
    printf '### Phase %s: %s\n**Goal:** %s\n**Deps:** none recorded during import\n' "$(jq -r '.number' <<< "$phase")" "$slug" "$goal"
    printf '**Reqs:** see REQUIREMENTS.md\n**Success:** unknown; imported status: %s\n\n' "$status"
  else
    printf '## Milestone: %s\n\n' "$slug"
  fi
}

roadmap_lines() {
  local ir="$1" lines='' phase
  while IFS= read -r phase; do
    # Command substitution drops trailing newlines, so the sentinel x preserves them.
    lines+=$(roadmap_phase_lines "$phase"; printf x)
    lines="${lines%x}"
  done < <(jq -c '.phases[] | . + {phase_present:(.number != null)}' "$ir")
  [ -n "$lines" ] || lines='## Phases

- [ ] No phases were present in the imported source.'
  printf '%s' "${lines%$'\n\n'}"
}

render_roadmap() {
  local ir="$1" output="$2" name lines
  name=$(import_project_name "$ir")
  lines=$(roadmap_lines "$ir")
  write_text "$output/ROADMAP.md" "$MD_H1 $name Roadmap

Imported from an external plan source; see .meridian/imports/ for provenance.

$lines"
}

state_decision_rows() {
  local ir="$1" rows='' decision
  while IFS= read -r decision; do
    rows+="| $(jq -r '.text | gsub("\\|"; "\\|")' <<< "$decision") | $(date -u +%Y-%m-%d) | imported |"$'\n'
  done < <(jq -c '.decisions[]' "$ir")
  [ -n "$rows" ] || rows='| _(No decisions yet)_ | | |'
  printf '%s' "${rows%$'\n'}"
}

state_document() {
  local name="$1" phase="$2" total="$3" phase_name="$4" done_count="$5" plans="$6" progress="$7" rows="$8"
  cat <<EOF
$MD_H1 State

**Project:** $name

$MD_H2 Current Phase
Phase: $phase of $total ($phase_name)
Plans: $done_count/$plans
Progress: $progress%
Status: ready

$MD_H2 Key Decisions

| Decision | Date | Rationale |
|----------|------|-----------|
$rows

$MD_H2 Todos
_(None)_

$MD_H2 Blockers
_(None)_

$MD_H2 Activity Log
- $(date -u +%Y-%m-%d): Imported external plan source
EOF
}

render_state() {
  local ir="$1" output="$2" name rows total phase_name plans_total plans_done progress current_phase
  name=$(import_project_name "$ir")
  rows=$(state_decision_rows "$ir")
  total=$(jq -r '[.phases[] | select(.number != null)] | length' "$ir")
  current_phase=$(jq -r '[.phases[] | select(.number != null)] | sort_by(.number) | .[0].number // 1' "$ir")
  phase_name=$(jq -r --argjson current "$current_phase" '[.phases[] | select(.number == $current)][0].slug // "none"' "$ir")
  plans_total=$(jq -r --argjson current "$current_phase" '[.phases[] | select(.number == $current)][0].plans | if . == null then 0 else length end' "$ir")
  plans_done=$(jq -r --argjson current "$current_phase" '[.phases[] | select(.number == $current)][0].plans | if . == null then 0 else ([.[] | select(.summary_present == true)] | length) end' "$ir")
  if [ "$plans_total" -gt 0 ]; then progress=$((plans_done * 100 / plans_total)); else progress=0; fi
  write_text "$output/STATE.md" "$(state_document "$name" "$current_phase" "$total" "$phase_name" "$plans_done" "$plans_total" "$progress" "$rows")"
}

plan_front_matter() {
  local phase="$1" number="$2" title="$3"
  cat <<EOF
---
phase: $phase
plan: $number
title: $title
type: execute
wave: 1

depends_on: []
cross_phase_deps: []

autonomous: true
effort_override: balanced

strategy_rationale: "Imported plan; review before execution."
EOF
  plan_front_matter_tail
}

plan_front_matter_tail() {
  cat <<'EOF'
validation:
  riskiest_assumption: ""
  mvp_slice: ""
  metric: ""
  decision_rule: ""

skills_used: []
files_modified: []
files_touched: []
forbidden_commands: []

must_haves:
  truths: ["Imported plan content stays reviewable before execution"]
  artifacts: []
  key_links: []
---
EOF
}

plan_body_opening() {
  local source_path="$1" status="$2" warning="$3"
  cat <<EOF
<objective>
Imported plan from $source_path. Review before execution.
</objective>
<context>
Source status: $status$warning
</context>
<tasks>
<task type="auto">
  <name>review-imported-plan</name>
  <files>
    $source_path
  </files>
EOF
}

plan_body_task() {
  cat <<'EOF'
  <strategy>spike</strategy>
  <estimate>1-2h</estimate>
  <depends_on>[]</depends_on>
  <action>
Review the imported plan content below and reconcile it with the project roadmap before executing any work.
  </action>
  <verify>
The imported content matches the source artifact and the reviewer has accepted or rewritten it.
  </verify>
  <done>
Imported content is reviewed and either accepted or replaced.
  </done>
</task>
</tasks>
<verification>
1. Imported content matches the source artifact.
</verification>
<success_criteria>
- Imported plan reviewed
</success_criteria>
EOF
}

plan_body_closing() {
  local number="$1" content="$2"
  cat <<EOF
<output>
${number}-SUMMARY.md
</output>

$MD_H2 Imported content

$content
EOF
}

render_plan_document() {
  local ir="$1" plan_json="$2" number title source_path status warning='' content heading phase
  number=$(jq -r 'if .number == null then 1 else .number end' <<< "$plan_json")
  title=$(jq -r '.title // "Imported plan"' <<< "$plan_json")
  source_path=$(jq -r '.source_path' <<< "$plan_json")
  status=$(jq -r '.status // "unknown"' <<< "$plan_json")
  if [ "$(jq -r '.source.system' "$ir")" = markdown ]; then
    warning=$'\n'"WARNING: unverified generic Markdown import; status and dependencies are unknown."$'\n'
  fi
  content=$(jq -r '.content // ""' <<< "$plan_json")
  heading=$(import_adapter_read_heading - <<< "$content" || true)
  if [ -n "$content" ] && [ "$heading" != "$title" ]; then
    content=$'# '"$title"$'\n\n'"$content"
  fi
  [ -n "$content" ] || content="# $title"
  phase=$(jq -r 'if .phase == null then 1 else .phase end' <<< "$plan_json")
  write_text "$3" "$(plan_front_matter "$phase" "$number" "$title")
$(plan_body_opening "$source_path" "$status" "$warning")
$(plan_body_task)
$(plan_body_closing "$number" "$content")"
}

plan_destination() {
  local ir="$1" output="$2" plan="$3" phase phase_slug number base
  if [ "$(jq -r '.phase != null' <<< "$plan")" = true ]; then
    phase=$(jq -r '.phase' <<< "$plan")
    phase_slug=$(jq -r --argjson n "$phase" '[.phases[] | select(.number == $n)][0].slug // "imported"' "$ir")
    number=$(jq -r 'if .number == null then 1 else .number end' <<< "$plan")
    PLAN_DESTINATION="$output/phases/$(printf '%02d-%s' "$phase" "$phase_slug")/$(printf '%02d-%02d-PLAN.md' "$phase" "$number")"
  else
    base=$(basename "$(jq -r '.source_path' <<< "$plan")" .md)
    PLAN_DESTINATION="$output/imported-markdown/$(printf '%s' "$base" | tr '/ ' '__').md"
  fi
}

write_plan_summary() {
  local plan="$1" destination="$2"
  [ "$(jq -r '.phase != null' <<< "$plan")" = true ] || return 0
  [ "$(jq -r '.summary_present // false' <<< "$plan")" = true ] || return 0
  write_text "${destination%-PLAN.md}-SUMMARY.md" "$MD_H1 $(jq -r '.title // "Imported plan"' <<< "$plan") Summary

Result: complete (imported; source summary presence detected by the verified adapter)

Source: $(jq -r '.source_path' <<< "$plan")"
}

render_plans() {
  local ir="$1" output="$2" plan
  while IFS= read -r plan; do
    plan_destination "$ir" "$output" "$plan"
    write_plan_summary "$plan" "$PLAN_DESTINATION"
    render_plan_document "$ir" "$plan" "$PLAN_DESTINATION"
  done < <(jq -c '.plans[]' "$ir")
}

render_tree() {
  local ir="$1" tree="$2"
  rm -rf "$tree"
  mkdir -p "$tree/.meridian"
  render_project "$ir" "$tree/.meridian"
  render_requirements "$ir" "$tree/.meridian"
  render_roadmap "$ir" "$tree/.meridian"
  render_state "$ir" "$tree/.meridian"
  render_config "$tree/.meridian"
  render_plans "$ir" "$tree/.meridian"
}
