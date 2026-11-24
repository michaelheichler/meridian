#!/usr/bin/env bats

load gate_case_helper
load gate_case_files
load rejection_case_helper

build_sandbox() {
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/.claude-plugin"
  cp "$BATS_TEST_DIRNAME/../scripts/version-bump.sh" "$SANDBOX/scripts/version-bump.sh"
  cp "$BATS_TEST_DIRNAME/../scripts/release-verify.sh" "$SANDBOX/scripts/release-verify.sh"
  cp "$BATS_TEST_DIRNAME/../scripts/rtk-manager.sh" "$SANDBOX/scripts/rtk-manager.sh"
  chmod +x "$SANDBOX/scripts/version-bump.sh" "$SANDBOX/scripts/release-verify.sh" "$SANDBOX/scripts/rtk-manager.sh"
  printf '1.0.0\n' > "$SANDBOX/VERSION"
  printf '{"name":"meridian","version":"1.0.0"}\n' > "$SANDBOX/.claude-plugin/plugin.json"
  printf '{"name":"meridian-marketplace","version":"1.0.0","owner":{"name":"Test"},"plugins":[{"name":"meridian","source":".","version":"1.0.0"}]}\n' > "$SANDBOX/.claude-plugin/marketplace.json"
  printf '%s\n' '# Changelog' '' '## [1.0.0] - 2026-08-09' '' '### Added' '' '- Initial release candidate.' > "$SANDBOX/CHANGELOG.md"
}

setup() {
  TEST_ROOT="$(mktemp -d)"
  SANDBOX="$TEST_ROOT/repo"
  build_sandbox
}

teardown() {
  rm -rf "$TEST_ROOT"
}

version_bump() {
  bash "$SANDBOX/scripts/version-bump.sh" "$@"
}

bump_changelog_to_1_0_1() {
  sed -i.bak 's/1.0.0/1.0.1/g' "$SANDBOX/CHANGELOG.md"
  rm "$SANDBOX/CHANGELOG.md.bak"
}

sandbox_digest() {
  (cd "$SANDBOX" && find . -type f -exec cksum {} + | sort)
}

expect_sandbox_version() {
  local label="$1" want="$2"
  [ "$(tr -d '[:space:]' < "$SANDBOX/VERSION")" = "$want" ] || record_case_failure "$label" "VERSION is not $want"
  [ "$(jq -r '.version' "$SANDBOX/.claude-plugin/plugin.json")" = "$want" ] || record_case_failure "$label" "plugin version is not $want"
}

@test "version-bump verifies, dry-runs and sets synchronized metadata and rejects drift or unconfirmed sets with exit 2" {
  local before
  reset_case_failures

  before=$(sandbox_digest)
  run version_bump --verify
  expect_case verify-synchronized 0 '1.0.0 is synchronized'
  expect_digest verify-synchronized "$before" "$(sandbox_digest)"

  bump_changelog_to_1_0_1
  before=$(sandbox_digest)
  run version_bump --set 1.0.1 --yes --dry-run
  expect_case dry-run 0 'dry-run'
  expect_digest dry-run "$before" "$(sandbox_digest)"
  expect_sandbox_version dry-run 1.0.0

  run version_bump --set 1.0.1 --yes
  expect_status set-confirmed 0
  expect_sandbox_version set-confirmed 1.0.1
  [ "$(jq -r '.version' "$SANDBOX/.claude-plugin/marketplace.json")" = 1.0.1 ] \
    || record_case_failure set-confirmed "marketplace version is not 1.0.1"
  [ "$(jq -r '.plugins[0].version' "$SANDBOX/.claude-plugin/marketplace.json")" = 1.0.1 ] \
    || record_case_failure set-confirmed "marketplace plugin version is not 1.0.1"

  build_sandbox
  printf '{"name":"meridian","version":"1.0.1"}\n' > "$SANDBOX/.claude-plugin/plugin.json"
  run version_bump --verify
  expect_case plugin-drift 2 'does not match VERSION'

  build_sandbox
  jq '.version = "1.0.1"' "$SANDBOX/.claude-plugin/marketplace.json" > "$SANDBOX/marketplace.tmp"
  mv "$SANDBOX/marketplace.tmp" "$SANDBOX/.claude-plugin/marketplace.json"
  run version_bump --verify
  expect_case marketplace-drift 2 'marketplace version'

  build_sandbox
  before=$(sandbox_digest)
  run version_bump --set 1.0.1
  expect_case set-without-confirmation 2 'requires --yes'
  expect_digest set-without-confirmation "$before" "$(sandbox_digest)"
  [ "$(tr -d '[:space:]' < "$SANDBOX/VERSION")" = 1.0.0 ] || record_case_failure set-without-confirmation "VERSION changed"

  assert_no_case_failures
}

write_changelog_with_unreleased() {
  printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '### Changed' '' '- Pending work.' '' "$@" > "$SANDBOX/CHANGELOG.md"
}

@test "an Unreleased section above the newest release heading passes verify, set and release-verify" {
  local before
  reset_case_failures

  write_changelog_with_unreleased '## [1.0.0] - 2026-08-09' '' '- Initial release candidate.'
  before=$(sandbox_digest)
  run version_bump --verify
  expect_case unreleased-verify 0
  expect_digest unreleased-verify "$before" "$(sandbox_digest)"

  run bash "$SANDBOX/scripts/release-verify.sh"
  expect_case unreleased-release-verify 0

  write_changelog_with_unreleased '## [1.0.1] - 2026-09-01' '' '- Fixes.' '' '## [1.0.0] - 2026-08-09' '' '- Initial release candidate.'
  run version_bump --set 1.0.1 --yes
  expect_case unreleased-set 0
  expect_sandbox_version unreleased-set 1.0.1

  assert_no_case_failures
}

@test "release-verify validates local release metadata without publishing" {
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
