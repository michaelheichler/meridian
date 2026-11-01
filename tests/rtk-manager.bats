#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/project/scripts"
  export RTK_TEST_ROOT="$(cd "$TEST_TEMP_DIR/project" && pwd -P)"
  cp "$SCRIPTS_DIR/rtk-manager.sh" "$RTK_TEST_ROOT/scripts/rtk-manager.sh"
  chmod +x "$RTK_TEST_ROOT/scripts/rtk-manager.sh"
  export LBWC_RTK_DIR="$RTK_TEST_ROOT/.lbwc-planning/tools/rtk"
  export LBWC_RTK_BINARY="$LBWC_RTK_DIR/rtk"
  export LBWC_RTK_RECEIPT="$LBWC_RTK_DIR/rtk-install.json"
  export LBWC_RTK_BACKUPS="$LBWC_RTK_DIR/backups"
  export RTK_REPO_API='https://fixture.invalid/release.json'
  export PATH="$TEST_TEMP_DIR/bin:$PATH"
  mkdir -p "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR/release/payload"
  write_fake_claude
  write_fake_curl
  prepare_release
  cd "$RTK_TEST_ROOT"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

manager() {
  bash "$RTK_TEST_ROOT/scripts/rtk-manager.sh" "$@"
}

reset_rtk() {
  rm -rf "$LBWC_RTK_DIR"
  export LBWC_RTK_BACKUPS="$LBWC_RTK_DIR/backups"
  unset RTK_FIXTURE_PROXY_FAILURE
  prepare_release
}

count_files_named() {
  find "$LBWC_RTK_BACKUPS" -type f -name "$1" 2>/dev/null | wc -l | tr -d '[:space:]'
}

target_name() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64|Darwin:aarch64) printf '%s\n' 'aarch64-apple-darwin' ;;
    Darwin:x86_64) printf '%s\n' 'x86_64-apple-darwin' ;;
    Linux:arm64|Linux:aarch64) printf '%s\n' 'aarch64-unknown-linux-gnu' ;;
    *) printf '%s\n' 'x86_64-unknown-linux-musl' ;;
  esac
}

sha256_value() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

write_fake_claude() {
  cat > "$TEST_TEMP_DIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 2
printf 'Claude Code fixture\n'
EOF
  chmod +x "$TEST_TEMP_DIR/bin/claude"
}

write_fake_curl() {
  cat > "$TEST_TEMP_DIR/bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
url=''
output=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) output="\$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  https://fixture.invalid/release.json) source="$TEST_TEMP_DIR/release/release.json" ;;
  https://fixture.invalid/checksums.txt) source="$TEST_TEMP_DIR/release/checksums.txt" ;;
  https://fixture.invalid/rtk-*.tar.gz) source="$TEST_TEMP_DIR/release/archive.tar.gz" ;;
  *) exit 44 ;;
esac
if [ -n "\$output" ]; then
  cp "\$source" "\$output"
else
  cat "\$source"
fi
EOF
  chmod +x "$TEST_TEMP_DIR/bin/curl"
}

prepare_release() {
  local target asset checksum
  target="$(target_name)"
  asset="rtk-${target}.tar.gz"
  cat > "$TEST_TEMP_DIR/release/payload/rtk" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'rtk 9.9.9\n' ;;
  proxy)
    [ "${RTK_FIXTURE_PROXY_FAILURE:-false}" = true ] && exit 81
    shift
    "$@"
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TEST_TEMP_DIR/release/payload/rtk"
  tar -czf "$TEST_TEMP_DIR/release/archive.tar.gz" -C "$TEST_TEMP_DIR/release/payload" rtk
  checksum="$(sha256_value "$TEST_TEMP_DIR/release/archive.tar.gz")"
  printf '%s  %s\n' "$checksum" "$asset" > "$TEST_TEMP_DIR/release/checksums.txt"
  cat > "$TEST_TEMP_DIR/release/release.json" <<EOF
{"tag_name":"v9.9.9","assets":[
  {"name":"$asset","browser_download_url":"https://fixture.invalid/$asset"},
  {"name":"checksums.txt","browser_download_url":"https://fixture.invalid/checksums.txt"}
]}
EOF
}

build_archive_with_entry() {
  python3 -I -c '
import io, sys, tarfile
out, name = sys.argv[1], sys.argv[2]
payload = b"bad\n"
with tarfile.open(out, "w:gz") as archive:
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    info.mode = 0o755
    archive.addfile(info, io.BytesIO(payload))
' "$TEST_TEMP_DIR/release/archive.tar.gz" "$1"
  printf '%s  rtk-%s.tar.gz\n' "$(sha256_value "$TEST_TEMP_DIR/release/archive.tar.gz")" "$(target_name)" > "$TEST_TEMP_DIR/release/checksums.txt"
}

expect_needs_yes() {
  reset_rtk
  run manager "$1"
  expect_case "$1-needs-yes" 2 "$1 requires --yes"
  expect_no_path "$1-needs-yes-installs-nothing" "$LBWC_RTK_BINARY"
}

@test "rtk-manager usage and guards: reports status, rejects bad invocations, demands --yes and keeps state inside the project" {
  run manager status --json
  expect_status status-missing 0
  expect_jq_output status-missing '.installed == false'
  expect_output_has status-missing "$LBWC_RTK_BINARY"

  run manager
  expect_case no-command 2 "Usage: rtk-manager.sh"

  run manager bogus
  expect_case unknown-command 2 "unknown command bogus"

  run manager status --bogus
  expect_case unknown-option 2 "unknown option --bogus"

  run manager --help
  expect_case help-flag 0 "Usage: rtk-manager.sh"

  run manager status --help
  expect_case help-after-command 0 "Usage: rtk-manager.sh"

  expect_needs_yes install
  expect_needs_yes update
  expect_needs_yes uninstall

  run env LBWC_RTK_DIR="$TEST_TEMP_DIR/outside" bash "$RTK_TEST_ROOT/scripts/rtk-manager.sh" status
  expect_case state-outside-project 2 "state must stay inside this project"

  mkdir -p "$TEST_TEMP_DIR/outside"
  ln -s "$TEST_TEMP_DIR/outside" "$RTK_TEST_ROOT/escape"
  run env -u LBWC_RTK_BINARY -u LBWC_RTK_RECEIPT -u LBWC_RTK_BACKUPS LBWC_RTK_DIR="$RTK_TEST_ROOT/escape/rtk" bash "$RTK_TEST_ROOT/scripts/rtk-manager.sh" install --yes
  expect_case symlink-traversal 2 "may not traverse symbolic links"
  expect_no_path symlink-traversal "$TEST_TEMP_DIR/outside/rtk"

  assert_no_case_failures
}

@test "rtk-manager install: validates a dry run, writes a receipt that verify accepts, and refuses bad checksums and unsafe archive paths" {
  reset_rtk
  run manager install --yes --dry-run
  expect_case dry-run 0 "dry-run: install RTK v9.9.9"
  expect_no_path dry-run "$LBWC_RTK_BINARY"
  expect_no_path dry-run "$LBWC_RTK_RECEIPT"

  run manager install --yes
  expect_status install 0
  [ -x "$LBWC_RTK_BINARY" ] || record_case_failure install "binary is not executable"
  expect_path install "$LBWC_RTK_RECEIPT"
  expect_jq install "$LBWC_RTK_RECEIPT" '.release.tag == "v9.9.9" and .claude_code_smoke == "available"'

  run manager verify --json
  expect_status verify 0
  expect_jq_output verify '.verified == true and .claude_code_smoke == "available"'

  run manager status --json
  expect_status status-installed 0
  expect_jq_output status-installed '.installed == true'

  reset_rtk
  printf '%064d  rtk-%s.tar.gz\n' 0 "$(target_name)" > "$TEST_TEMP_DIR/release/checksums.txt"
  run manager install --yes
  expect_case checksum-mismatch 2 "checksum mismatch"
  expect_no_path checksum-mismatch "$LBWC_RTK_BINARY"

  reset_rtk
  build_archive_with_entry 'dir/../rtk'
  run manager install --yes
  expect_case archive-parent-traversal 2 "unsafe or empty paths"
  expect_no_path archive-parent-traversal "$LBWC_RTK_BINARY"

  reset_rtk
  build_archive_with_entry '/rtk'
  run manager install --yes
  expect_case archive-absolute-path 2 "unsafe or empty paths"
  expect_no_path archive-absolute-path "$LBWC_RTK_BINARY"

  assert_no_case_failures
}

@test "rtk-manager update: backs up first and rolls back when the smoke check fails" {
  local before_binary before_receipt

  reset_rtk
  manager install --yes
  printf 'old binary\n' > "$LBWC_RTK_BINARY"
  chmod +x "$LBWC_RTK_BINARY"
  run manager update --yes
  expect_status update-backup 0
  [ "$(count_files_named rtk)" = 1 ] || record_case_failure update-backup "expected one backed up binary"
  [ "$(count_files_named rtk-install.json)" = 1 ] || record_case_failure update-backup "expected one backed up receipt"
  run "$LBWC_RTK_BINARY" --version
  expect_case update-backup-runs 0 "rtk 9.9.9"

  reset_rtk
  manager install --yes
  before_binary="$(sha256_value "$LBWC_RTK_BINARY")"
  before_receipt="$(sha256_value "$LBWC_RTK_RECEIPT")"
  printf 'blocked\n' > "$LBWC_RTK_DIR/blocked"
  export LBWC_RTK_BACKUPS="$LBWC_RTK_DIR/blocked"
  run manager update --yes
  expect_case backup-failure 2 "could not create a backup"
  expect_same_digest backup-failure "$LBWC_RTK_BINARY" "$before_binary"
  expect_same_digest backup-failure "$LBWC_RTK_RECEIPT" "$before_receipt"

  reset_rtk
  manager install --yes
  before_binary="$(sha256_value "$LBWC_RTK_BINARY")"
  before_receipt="$(sha256_value "$LBWC_RTK_RECEIPT")"
  export RTK_FIXTURE_PROXY_FAILURE=true
  run manager update --yes
  expect_case smoke-failure 2 "compatibility smoke check"
  expect_same_digest smoke-failure "$LBWC_RTK_BINARY" "$before_binary"
  expect_same_digest smoke-failure "$LBWC_RTK_RECEIPT" "$before_receipt"

  assert_no_case_failures
}

@test "rtk-manager uninstall: a dry run keeps the install and a confirmed run keeps a backup" {
  reset_rtk
  manager install --yes
  run manager uninstall --yes --dry-run
  expect_status uninstall-dry-run 0
  [ -x "$LBWC_RTK_BINARY" ] || record_case_failure uninstall-dry-run "dry run removed the binary"

  run manager uninstall --yes
  expect_case uninstall 0 "uninstall: removed project-local RTK install"
  expect_no_path uninstall "$LBWC_RTK_BINARY"
  expect_no_path uninstall "$LBWC_RTK_RECEIPT"
  [ "$(count_files_named rtk)" = 1 ] || record_case_failure uninstall "expected one backed up binary"

  assert_no_case_failures
}
