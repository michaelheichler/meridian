#!/usr/bin/env bats

setup() {
  TEST_ROOT="$(mktemp -d)"
  SANDBOX="$TEST_ROOT/repo"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/.claude-plugin"
  cp "$BATS_TEST_DIRNAME/../scripts/version-bump.sh" "$SANDBOX/scripts/version-bump.sh"
  cp "$BATS_TEST_DIRNAME/../scripts/release-verify.sh" "$SANDBOX/scripts/release-verify.sh"
  cp "$BATS_TEST_DIRNAME/../scripts/rtk-manager.sh" "$SANDBOX/scripts/rtk-manager.sh"
  chmod +x "$SANDBOX/scripts/version-bump.sh" "$SANDBOX/scripts/release-verify.sh" "$SANDBOX/scripts/rtk-manager.sh"
  printf '1.0.0\n' > "$SANDBOX/VERSION"
  printf '{"name":"lbwc","version":"1.0.0"}\n' > "$SANDBOX/.claude-plugin/plugin.json"
  printf '{"name":"lbwc-marketplace","version":"1.0.0","owner":{"name":"Test"},"plugins":[{"name":"lbwc","source":".","version":"1.0.0"}]}\n' > "$SANDBOX/.claude-plugin/marketplace.json"
  printf '%s\n' '# Changelog' '' '## [1.0.0] - 2026-08-09' '' '### Added' '' '- Initial release candidate.' > "$SANDBOX/CHANGELOG.md"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

version_bump() {
  bash "$SANDBOX/scripts/version-bump.sh" "$@"
}

@test "version-bump: verify requires synchronized metadata and newest changelog entry" {
  run version_bump --verify

  [ "$status" -eq 0 ]
  [[ "$output" == *'1.0.0 is synchronized'* ]]
}

@test "version-bump: verify rejects plugin metadata drift" {
  printf '{"name":"lbwc","version":"1.0.1"}\n' > "$SANDBOX/.claude-plugin/plugin.json"

  run version_bump --verify

  [ "$status" -eq 2 ]
  [[ "$output" == *'does not match VERSION'* ]]
}

@test "version-bump: verify rejects marketplace metadata drift" {
  jq '.version = "1.0.1"' "$SANDBOX/.claude-plugin/marketplace.json" > "$SANDBOX/marketplace.tmp"
  mv "$SANDBOX/marketplace.tmp" "$SANDBOX/.claude-plugin/marketplace.json"

  run version_bump --verify

  [ "$status" -eq 2 ]
  [[ "$output" == *'marketplace version'* ]]
}

@test "version-bump: setting a version requires confirmation" {
  run version_bump --set 1.0.1

  [ "$status" -eq 2 ]
  [[ "$output" == *'requires --yes'* ]]
  [ "$(tr -d '[:space:]' < "$SANDBOX/VERSION")" = 1.0.0 ]
}

@test "version-bump: dry-run does not change synchronized files" {
  sed -i.bak 's/1.0.0/1.0.1/g' "$SANDBOX/CHANGELOG.md"
  rm "$SANDBOX/CHANGELOG.md.bak"

  run version_bump --set 1.0.1 --yes --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *'dry-run'* ]]
  [ "$(tr -d '[:space:]' < "$SANDBOX/VERSION")" = 1.0.0 ]
  [ "$(jq -r '.version' "$SANDBOX/.claude-plugin/plugin.json")" = 1.0.0 ]
}

@test "version-bump: set updates VERSION and plugin after changelog discipline passes" {
  sed -i.bak 's/1.0.0/1.0.1/g' "$SANDBOX/CHANGELOG.md"
  rm "$SANDBOX/CHANGELOG.md.bak"

  run version_bump --set 1.0.1 --yes

  [ "$status" -eq 0 ]
  [ "$(tr -d '[:space:]' < "$SANDBOX/VERSION")" = 1.0.1 ]
  [ "$(jq -r '.version' "$SANDBOX/.claude-plugin/plugin.json")" = 1.0.1 ]
  [ "$(jq -r '.version' "$SANDBOX/.claude-plugin/marketplace.json")" = 1.0.1 ]
  [ "$(jq -r '.plugins[0].version' "$SANDBOX/.claude-plugin/marketplace.json")" = 1.0.1 ]
}

@test "release-verify: validates local release metadata without publishing" {
  run bash "$SANDBOX/scripts/release-verify.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *'separate publish decision'* ]]
}

non_executable_gated_scripts() {
  local repo_root="$BATS_TEST_DIRNAME/.." gated mode name found=0
  gated=$(grep -hoE '\[ -x "\$(SCRIPT_DIR|ROOT/scripts)/[A-Za-z0-9._-]+"' "$repo_root"/scripts/*.sh | sed -E 's|.*/([^/"]+)"$|\1|' | sort -u)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=1
    mode=$(git -C "$repo_root" ls-files -s -- "scripts/$name" | cut -d' ' -f1)
    [ "$mode" = 100755 ] || printf '%s has git mode %s\n' "$name" "${mode:-missing}"
  done <<< "$gated"
  [ "$found" = 1 ] || printf 'no executable-gated scripts found\n'
}

@test "every script that another script runs behind an executable check is executable in git" {
  run non_executable_gated_scripts

  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}
