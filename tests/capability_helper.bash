setup_capability_sandbox() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SCRIPT="$REPO_ROOT/scripts/claude-capabilities.sh"
  test_root="$(mktemp -d)"
  TEST_ROOT="$(cd "$test_root" && pwd -P)"
  PLANNING_DIR="$TEST_ROOT/project/.lbwc-planning"
  CATALOG="$PLANNING_DIR/claude-capabilities.json"
  INVOCATION_MARKER="$TEST_ROOT/model-invoked"
  mkdir -p "$PLANNING_DIR"
}

teardown_capability_sandbox() {
  rm -rf "$TEST_ROOT"
}

case_fail() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
}

write_claude_fixture() {
  local binary="$1" version="$2" efforts="$3" models_json="$4" associations="$5" unrelated_table="${6:-}" inspection_marker="${7:-}" host_enum="${8:-}"
  mkdir -p "$(dirname "$binary")"
  cat > "$binary" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n '$inspection_marker' ]; then
  printf '%s\n' used > '$inspection_marker'
fi
case "\${1:-}" in
  --version)
    printf '%s\n' '$version'
    ;;
  --help)
    printf '%s\n' '  --effort <level>  Session reasoning' '                      ($efforts)'
    ;;
  *)
    printf '%s\n' invoked > "$INVOCATION_MARKER"
    exit 97
    ;;
esac
exit 0
: 'models:$models_json'
: '$unrelated_table'
: '$associations'
: '$host_enum'
EOF
  chmod +x "$binary"
}

make_claude_fixture() {
  local binary="$1"
  write_claude_fixture \
    "$binary" \
    '91.7.3 (Fixture Code)' \
    'careful, brisk, exhaustive' \
    '[{id:"claude-amber-route",family:"amber",display_name:"Amber Route"},{id:"claude-violet-route",family:"violet",display_name:"Violet Route"}]' \
    '' \
    '' \
    '' \
    '["amber","violet"]'
}

catalog_matches() {
  jq -e "$@" "$CATALOG" >/dev/null || {
    echo "catalog did not match: $*" >&2
    cat "$CATALOG" >&2
    return 1
  }
}

file_sha() {
  shasum -a 256 "$1" | awk '{print $1}'
}
