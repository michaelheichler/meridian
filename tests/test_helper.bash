#!/bin/bash

unset CDPATH TMUX TMUX_PANE

export PROJECT_ROOT="${BATS_TEST_DIRNAME}/.."
export SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
export CONFIG_DIR="${PROJECT_ROOT}/config"

setup_temp_dir() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export _ORIG_HOME="${HOME:-}"
  export _ORIG_LBWC_PLANNING_DIR="${LBWC_PLANNING_DIR:-}"
  export HOME="$TEST_TEMP_DIR"
  unset LBWC_PLANNING_DIR CLAUDE_SESSION_ID 2>/dev/null || true
  mkdir -p "$TEST_TEMP_DIR/.lbwc-planning"
}

teardown_temp_dir() {
  [ -n "${TEST_TEMP_DIR:-}" ] && rm -rf "$TEST_TEMP_DIR"
  export HOME="$_ORIG_HOME"
  if [ -n "${_ORIG_LBWC_PLANNING_DIR:-}" ]; then
    export LBWC_PLANNING_DIR="$_ORIG_LBWC_PLANNING_DIR"
  else
    unset LBWC_PLANNING_DIR 2>/dev/null || true
  fi
  unset _ORIG_HOME _ORIG_LBWC_PLANNING_DIR
}

create_test_config() {
  local dir="${1:-.lbwc-planning}"
  echo '{}' > "$TEST_TEMP_DIR/$dir/config.json"
}

run_phase_detect() {
  local _pd_script_dir="${1:-$SCRIPTS_DIR}"
  local _pd_sleeps=(0.1 0.2 0.4 0.8)
  local _pd_attempt=0
  while [ $_pd_attempt -lt 5 ]; do
    run bash "$_pd_script_dir/phase-detect.sh"
    if [ -n "$output" ] && [[ "$output" == *"phase_detect_complete=true"* ]]; then
      return 0
    fi
    if [ $_pd_attempt -lt 4 ]; then
      sleep "${_pd_sleeps[$_pd_attempt]}"
    fi
    _pd_attempt=$((_pd_attempt + 1))
  done
  output="run_phase_detect: all 5 retries returned empty or incomplete output"
  export status=1
  echo "$output" >&2
  return 1
}

write_manifest() {
  local dir="$1" json="$2"
  mkdir -p "$dir"
  printf '%s' "$json" > "$dir/.agent-manifest.json"
}

payload() {
  python3 - "$@" <<'EOF'
import json
import sys

pairs = sys.argv[1:]
data = {}
for pair in pairs:
    key, _, value = pair.partition('=')
    node = data
    parts = key.split('.')
    for part in parts[:-1]:
        node = node.setdefault(part, {})
    node[parts[-1]] = value
print(json.dumps(data))
EOF
}

setup_unrelated_git_repo() {
  local repo_dir="$1"

  mkdir -p "$repo_dir"
  (
    cd "$repo_dir" || exit 1
    git init -q
    git config user.name "LBWC Test"
    git config user.email "lbwc-tests@example.com"
    echo "initial" > unrelated.txt
    git add unrelated.txt
    git commit -qm "init"
  )
}

_copy_libs_sourced_by() {
  local file="$1" libs_dest="$2" name
  while IFS= read -r name; do
    [ -n "$name" ] && [ -f "$SCRIPTS_DIR/lib/$name" ] || continue
    [ -e "$libs_dest/$name" ] && continue
    cp "$SCRIPTS_DIR/lib/$name" "$libs_dest/$name"
    _copy_lib_assets_referenced_by "$SCRIPTS_DIR/lib/$name" "$libs_dest"
    _copy_libs_sourced_by "$SCRIPTS_DIR/lib/$name" "$libs_dest"
  done < <(sed -nE 's/^[[:space:]]*(source|\.)[[:space:]].*lib\/([A-Za-z0-9_.-]+)["[:space:]]*.*$/\2/p' "$file")
}

_copy_lib_assets_referenced_by() {
  local file="$1" libs_dest="$2" name
  while IFS= read -r name; do
    [ -n "$name" ] && [ -e "$SCRIPTS_DIR/lib/$name" ] || continue
    [ -e "$libs_dest/$name" ] && continue
    cp -R "$SCRIPTS_DIR/lib/$name" "$libs_dest/$name"
    if [ -f "$SCRIPTS_DIR/lib/$name" ]; then
      _copy_lib_assets_referenced_by "$SCRIPTS_DIR/lib/$name" "$libs_dest"
    fi
  done < <(grep -oE '(lib/[A-Za-z0-9_.-]+|[A-Za-z0-9_-]+\.(jq|awk|py|tmpl))' "$file" | sed 's|^lib/||' | grep -v '\.sh$')
}

copy_script_with_libs() {
  local src="$1" dest="$2" base prefix dest_dir libs_dest lib
  base="$(basename "$src")"
  prefix="${base%.sh}"
  dest_dir="$(dirname "$dest")"
  libs_dest="$dest_dir/lib"
  [ "$(basename "$dest_dir")" = "lib" ] && libs_dest="$dest_dir"
  mkdir -p "$dest_dir" "$libs_dest"
  cp "$src" "$dest"
  for lib in "$SCRIPTS_DIR/lib/$prefix"-*.sh; do
    [ -f "$lib" ] || continue
    cp "$lib" "$libs_dest/$(basename "$lib")"
    _copy_lib_assets_referenced_by "$lib" "$libs_dest"
    _copy_libs_sourced_by "$lib" "$libs_dest"
  done
  _copy_lib_assets_referenced_by "$src" "$libs_dest"
  _copy_libs_sourced_by "$src" "$libs_dest"
}
