#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

RESOLVER="${SCRIPTS_DIR}/resolve-agent-settings.sh"

setup() {
  TEST_TEMP_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lbwc-resolver.XXXXXX")" && pwd -P)
  export TEST_TEMP_DIR
  export _ORIG_HOME="${HOME:-}"
  export _ORIG_LBWC_PLANNING_DIR="${LBWC_PLANNING_DIR:-}"
  export HOME="$TEST_TEMP_DIR"
  unset LBWC_PLANNING_DIR CLAUDE_SESSION_ID 2>/dev/null || true
  mkdir -p "$TEST_TEMP_DIR/.lbwc-planning"
  CONFIG_PATH="$TEST_TEMP_DIR/.lbwc-planning/config.json"
  write_catalog
  write_config
  cp "$CONFIG_PATH" "$CONFIG_PATH.pristine"
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

write_catalog() {
  local binary="$TEST_TEMP_DIR/claude-resolver-fixture" sha
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "fixture"' > "$binary"
  chmod +x "$binary"
  sha=$(shasum -a 256 "$binary" | awk '{print $1}')
  jq -n --arg binary "$binary" --arg sha "$sha" '
    {
      schema_version: 1,
      source: {binary_path: $binary, version: "fixture", sha256: $sha, detected_at: "2035-01-02T03:04:05Z"},
      models: [
        {selector: "nova-route", label: "Nova Route", description: "Fixture selector"},
        {selector: "ember-path", label: "Ember Path", description: "Second fixture selector"}
      ],
      reasoning: {
        scope: "global",
        accepted_values: ["deliberate", "swift", "default"],
        model_associations: {"nova-route": ["deliberate"]}
      }
    }
  ' > "$TEST_TEMP_DIR/.lbwc-planning/claude-capabilities.json"
}

write_config() {
  jq --slurpfile defaults "$PROJECT_ROOT/templates/agent-roles/defaults.json" '
    . + {
      schema_version: 1,
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {
            roles: ($defaults[0] | keys | map({key: ., value: {model: "nova-route", reasoning: "deliberate", status: "resolved"}}) | from_entries)
          },
          turbo: {roles: {}}
        }
      }
    }
  ' "$CONFIG_DIR/settings.json" > "$CONFIG_PATH"
}

reset_config() {
  cp "$CONFIG_PATH.pristine" "$CONFIG_PATH"
}

update_config() {
  jq "$1" "$CONFIG_PATH" > "$CONFIG_PATH.next"
  mv "$CONFIG_PATH.next" "$CONFIG_PATH"
}

resolve() {
  run bash "$RESOLVER" "$@"
}

@test "the resolver renders the saved or explicit route into renderer variables" {
  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT"
  expect_case profile-value 0 "RESOLVED_AGENT_MODEL='nova-route'"
  expect_fragment profile-value "RESOLVED_MODEL='nova-route'"
  expect_fragment profile-value "RESOLVED_REASONING='deliberate'"

  reset_config
  update_config '.routing.active_profile = "quality" | .routing.profiles.quality.roles.lead = {model: "ember-path", reasoning: "swift", status: "resolved"}'
  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT"
  expect_case active-profile-route 0 "RESOLVED_AGENT_MODEL='ember-path'"
  expect_fragment active-profile-route "RESOLVED_REASONING='swift'"

  reset_config
  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT" --model ember-path --reasoning swift
  expect_case cli-route-values 0 "RESOLVED_AGENT_MODEL='ember-path'"
  expect_fragment cli-route-values "RESOLVED_MODEL='ember-path'"
  expect_fragment cli-route-values "RESOLVED_REASONING='swift'"

  update_config '.routing.profiles.balanced.roles.docs.reasoning = null'
  resolve docs "$CONFIG_PATH" "$PROJECT_ROOT"
  expect_case null-reasoning 0 "RESOLVED_REASONING=''"
  expect_fragment null-reasoning "RESOLVED_EFFORT=''"

  reset_config
  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT" --model nova-route --reasoning swift
  expect_case global-reasoning-ignores-associations 0 "RESOLVED_REASONING='swift'"

  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT" --model nova-route --reasoning default
  expect_case reasoning-named-default 0 "RESOLVED_REASONING='default'"
  expect_fragment reasoning-named-default "RESOLVED_REASONING_JSON='\"default\"'"

  assert_no_case_failures
}

@test "the resolver fails closed on an unknown model or an absent route" {
  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT" --model missing-route
  expect_case unknown-model 3 "saved capability catalog"

  update_config 'del(.routing.profiles.balanced.roles.lead)'
  resolve lead "$CONFIG_PATH" "$PROJECT_ROOT"
  expect_case absent-active-route 1 "route is unresolved or absent"

  assert_no_case_failures
}

max_turns_row() {
  local label="$1" role="$2" filter="$3" args="$4" want="$5"
  local -a extra=()
  reset_config
  [ "$filter" = - ] || update_config "$filter"
  [ "$args" = - ] || read -ra extra <<< "$args"
  [ "$want" != none ] || want=""

  resolve "$role" "$CONFIG_PATH" "$PROJECT_ROOT" ${extra[@]+"${extra[@]}"}

  expect_case "$label" 0 "RESOLVED_MAX_TURNS='${want}'"
}

@test "max_turns resolves from the pinned role table, project overrides and the CLI flag" {
  while IFS='|' read -r label role filter args want; do
    [ -n "$label" ] || continue
    max_turns_row "$label" "$role" "$filter" "$args" "$want"
  done <<'CASES'
lead|lead|-|-|50
lead-critic|lead-critic|-|-|20
coding-dijkstra|coding-dijkstra|-|-|50
coding-dijkstra-critic|coding-dijkstra-critic|-|-|20
python-engineer|python-engineer|-|-|50
python-critic|python-critic|-|-|20
web-engineer|web-engineer|-|-|50
web-code-critic|web-code-critic|-|-|20
test-dev|test-dev|-|-|40
architect|architect|-|-|50
debugger|debugger|-|-|40
qa|qa|-|-|20
scout|scout|-|-|30
ux-oracle|ux-oracle|-|-|20
docs|docs|-|-|30
qa-author|qa-author|-|-|30
deviq|deviq|-|-|15
cli-flag-wins|lead|-|--max-turns 7|7
cli-zero-normalizes-to-empty|lead|-|--max-turns 0|none
cli-negative-normalizes-to-empty|lead|-|--max-turns -3|none
project-override-beats-defaults|python-engineer|.roles."python-engineer".max_turns = 99|-|99
cli-flag-beats-project-override|lead|.roles.lead.max_turns = 33|--max-turns 99|99
critic-project-override-beats-defaults|lead-critic|.roles."lead-critic".max_turns = 33|-|33
CASES

  assert_no_case_failures
}

render_row() {
  local label="$1" role="$2" name="$3" job="$4" model="$5" effort="$6"
  run bash "${SCRIPTS_DIR}/render-agent-template.sh" "$role" \
    NAME="$name" JOB="$job" MODEL="$model" EFFORT="$effort"
  expect_case "$label" 0 "$name"
}

@test "render-agent-template renders the role templates with the supplied settings" {
  render_row docs-template docs lbwc-docs-test "write a README" nova-route deliberate
  render_row qa-author-template qa-author lbwc-qa-author-test "write failing tests" ember-path swift

  assert_no_case_failures
}
