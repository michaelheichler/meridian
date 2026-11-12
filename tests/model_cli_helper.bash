write_model_claude_fixture() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    '  --version) printf "%s\\n" "fixture-version" ;;' \
    '  --help) printf "%s\\n" "  --effort <level> effort (depth-99, default)" ;;' \
    '  *) printf "%s\\n" "fixture" ;;' \
    'esac' \
    'exit 0' \
    '# models:[{id:"claude-quartz-route",family:"quartz",display_name:"Quartz Route"},{id:"claude-ember-path",family:"ember",display_name:"Ember Path"}]' \
    > "$1"
  chmod +x "$1"
}

write_model_config() {
  jq '
    . + {
      schema_version: 1,
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {roles: {}},
          turbo: {roles: {}}
        }
      }
    }
  ' "$REPO_ROOT/config/settings.json" > "$1"
}

write_model_catalog() {
  jq -n --arg binary "$1" --arg sha "$2" '
    {
      schema_version: 1,
      source: {
        binary_path: $binary,
        version: "fixture",
        sha256: $sha,
        detected_at: "2035-01-02T03:04:05Z"
      },
      models: [
        {selector: "quartz|route", label: "Quartz | Route\nLine\u001b]0;owned\u0007", description: "Arbitrary fixture"},
        {selector: "ember-path", label: null, description: null}
      ],
      reasoning: {
        scope: "global",
        accepted_values: ["depth-99", "default"],
        model_associations: {}
      }
    }
  ' > "$3"
}

setup_model_sandbox() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/meridian-model"
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/meridian-model.XXXXXX")
  PLANNING_DIR="$TEST_ROOT/.meridian"
  CATALOG="$PLANNING_DIR/claude-capabilities.json"
  CLAUDE_FIXTURE="$TEST_ROOT/claude-fixture"
  mkdir -p "$PLANNING_DIR"
  write_model_claude_fixture "$CLAUDE_FIXTURE"
  write_model_config "$PLANNING_DIR/config.json"
  write_model_catalog "$CLAUDE_FIXTURE" "$(shasum -a 256 "$CLAUDE_FIXTURE" | awk '{print $1}')" "$CATALOG"
}

teardown_model_sandbox() {
  rm -rf "$TEST_ROOT"
}

case_fail() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
}

config_sha() {
  shasum -a 256 "$PLANNING_DIR/config.json" | awk '{print $1}'
}

file_sha_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

catalog_sha() {
  shasum -a 256 "$CATALOG" | awk '{print $1}'
}

install_shim() {
  local shim_dir="$1" name="$2" interpreter="${3:-/usr/bin/env bash}"
  mkdir -p "$shim_dir"
  { printf '#!%s\nset -euo pipefail\n' "$interpreter"; cat; } > "$shim_dir/$name"
  chmod +x "$shim_dir/$name"
}

wait_for_path() {
  local path="$1" attempt
  for attempt in $(seq 1 500); do
    [ -e "$path" ] && return 0
    sleep 0.01
  done
  return 1
}

physical_planning_dir() {
  (cd -P "$PLANNING_DIR" && pwd -P)
}
