#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  PROJECT="$TEST_TEMP_DIR/project"
  export CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/claude-home"
  mkdir -p "$PROJECT/src" "$PROJECT/.claude/skills/python-skill" "$CLAUDE_CONFIG_DIR"
  : > "$PROJECT/src/run.sh"
  : > "$PROJECT/Dockerfile"
  printf '%s\n' flask > "$PROJECT/requirements.txt"
}

teardown() {
  unset CLAUDE_CONFIG_DIR
  teardown_temp_dir
}

@test "detect-stack reports each detected stack once and suggests only skills the project lacks" {
  run bash "$SCRIPTS_DIR/detect-stack.sh" "$PROJECT"
  [ "$status" -eq 0 ]
  jq -e '
    (.detected_stack | sort) == ["bash", "docker", "flask", "python"]
    and (.recommended_skills | sort) == ["bash-skill", "docker-skill", "python-skill"]
    and (.suggestions | sort) == ["bash-skill", "docker-skill"]
    and .installed.project == ["python-skill"]
  ' <<< "$output" >/dev/null
}
