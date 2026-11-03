snapshot() {
  python3 -I "$RENAME_FIXTURE" manifest "$1"
}

seed_planning() {
  mkdir -p .lbwc-planning/journal-archive .lbwc-planning/.hidden
  printf 'configuration\n' > .lbwc-planning/config.json
  printf 'live café\n' > .lbwc-planning/JOURNAL.md
  printf 'archived\000bytes\n' > .lbwc-planning/journal-archive/older.md
  printf 'hidden\n' > .lbwc-planning/.hidden/token
}

migrate() {
  "$RENAME_SHELL" -c 'source "$1"; meridian_migrate_planning "$2"' rename "$RENAME_LIBRARY" "$PWD"
}

one_diagnostic() {
  [ "${#lines[@]}" -eq 1 ] || { printf 'Expected one diagnostic, got [%s]\n' "$output"; return 1; }
  [ -n "$output" ]
}

migration_old_only() {
  seed_planning
  snapshot .lbwc-planning > "$BATS_TEST_TMPDIR/before"
  run migrate
  [ "$status" -eq 0 ]
  one_diagnostic
  [ ! -e .lbwc-planning ]
  snapshot .meridian > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

migration_refused() {
  snapshot . > "$BATS_TEST_TMPDIR/before"
  run migrate
  [ "$status" -eq 0 ]
  one_diagnostic
  snapshot . > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

migration_both() {
  seed_planning
  mkdir .meridian
  printf 'different configuration\n' > .meridian/config.json
  snapshot . > "$BATS_TEST_TMPDIR/before"
  run "$RENAME_SHELL" -c '
    source "$1"
    meridian_migrate_planning "$2"
    [ "$MERIDIAN_MIGRATION_CONFLICT" = 0 ] || exit 23
    printf unexpected-continuation
  ' rename "$RENAME_LIBRARY" "$PWD"
  [ "$status" -eq 23 ]
  one_diagnostic
  snapshot . > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

migration_noop() {
  snapshot . > "$BATS_TEST_TMPDIR/before"
  run migrate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  snapshot . > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

migration_new_only() {
  seed_planning
  mv .lbwc-planning .meridian
  migration_noop
}

migration_neither() { migration_noop; }

migration_repeated() {
  seed_planning
  migrate > "$BATS_TEST_TMPDIR/first" 2>&1
  migration_noop
}

migration_destination_file() {
  seed_planning
  printf 'do not overwrite\n' > .meridian
  migration_refused
}

migration_destination_symlink() {
  seed_planning
  ln -s missing-target .meridian
  migration_refused
}

migration_source_symlink() {
  mkdir elsewhere
  printf 'external data\n' > elsewhere/data
  ln -s elsewhere .lbwc-planning
  migration_refused
}

migration_unwritable() {
  seed_planning
  snapshot . > "$BATS_TEST_TMPDIR/before"
  chmod a-w .
  run migrate
  chmod u+w .
  [ "$status" -ne 0 ]
  one_diagnostic
  snapshot . > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

environment_case() {
  local expected=$1
  shift
  run env -u LBWC_TEST_OPTION -u MERIDIAN_TEST_OPTION "$@" \
    "$RENAME_SHELL" -c '
      source "$1"
      meridian_migrate_environment
      python3 -I "$2" snapshot-environment
    ' rename "$RENAME_LIBRARY" "$RENAME_FIXTURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  run env -u LBWC_TEST_OPTION -u MERIDIAN_TEST_OPTION "$@" \
    python3 -I "$RENAME_FIXTURE" environment "$PROJECT_ROOT/hooks/rename_migration.py"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

environment_unset() {
  environment_case '{"LBWC_TEST_OPTION": "old value 日本語", "MERIDIAN_TEST_OPTION": "old value 日本語"}' \
    'LBWC_TEST_OPTION=old value 日本語'
}

environment_current() {
  environment_case '{"LBWC_TEST_OPTION": "old", "MERIDIAN_TEST_OPTION": "new"}' \
    'LBWC_TEST_OPTION=old' 'MERIDIAN_TEST_OPTION=new'
}

environment_empty() {
  environment_case '{"LBWC_TEST_OPTION": "old", "MERIDIAN_TEST_OPTION": ""}' \
    'LBWC_TEST_OPTION=old' 'MERIDIAN_TEST_OPTION='
}

environment_legacy_empty() {
  environment_case '{"LBWC_TEST_OPTION": "", "MERIDIAN_TEST_OPTION": ""}' LBWC_TEST_OPTION=
}

environment_no_legacy() { environment_case '{}'; }

preview_setup() {
  mkdir -p scripts/dev
  cp "$SCRIPTS_DIR/dev/rename-map.tsv" scripts/dev/
  cp "$SCRIPTS_DIR/dev/rename-apply.sh" scripts/dev/
}

preview_expect() {
  local name=$1 paths=$2 contents=$3 target=$4
  snapshot . > "$BATS_TEST_TMPDIR/before"
  run "$RENAME_SHELL" "$PWD/scripts/dev/rename-apply.sh" --dry-run
  [ "$status" -eq 0 ]
  snapshot . > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [[ "$output" == *"path_renames=$paths content_replacements=$contents "* ]]
  [[ "$output" == *"$name"$'\t'"path_renames=$paths"$'\t'"content_replacements=$contents"$'\t'"target=$target"* ]]
}

preview_unchanged() {
  local summary=$1
  snapshot . > "$BATS_TEST_TMPDIR/before"
  run "$RENAME_SHELL" "$PWD/scripts/dev/rename-apply.sh" --dry-run
  [ "$status" -eq 0 ]
  snapshot . > "$BATS_TEST_TMPDIR/after"
  cmp "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [[ "$output" == *'affected_files=0 path_renames=0 content_replacements=0 '* ]]
  [[ "$output" == *"$summary"* ]]
}

preview_command() {
  preview_setup
  printf '/lbwc:vibe\n' > usage.md
  preview_expect usage.md 0 1 usage.md
}

preview_boundaries() {
  preview_setup
  printf 'vibrant revibe vibes /vibes /vibeish\n' > usage.md
  preview_unchanged 'binary_files=0'
}

preview_keeps() {
  preview_setup
  awk -F '\t' '$4 ~ /^preserve / {print $2}' scripts/dev/rename-map.tsv > usage.md
  [ -s usage.md ]
  preview_unchanged 'binary_files=0'
}

preview_path() {
  local source target
  preview_setup
  source=$(awk -F '\t' '$1 == "path" && $4 == "literal" {print $2; exit}' scripts/dev/rename-map.tsv)
  target=$(awk -F '\t' '$1 == "path" && $4 == "literal" {print $3; exit}' scripts/dev/rename-map.tsv)
  mkdir -p "$(dirname "$source")"
  printf 'fixture\n' > "$source"
  preview_expect "$source" 1 0 "$target"
}

preview_excluded() {
  preview_setup
  printf '/lbwc:vibe\n' > CHANGELOG.md
  mkdir -p .claude/worktrees/nested
  printf '/lbwc:vibe\n' > .claude/worktrees/nested/usage.md
  git add -f .claude/worktrees/nested/usage.md
  preview_unchanged 'excluded_files=4'
}

preview_binary() {
  preview_setup
  printf '\000/lbwc:vibe\n' > nul.bin
  printf '\377/lbwc:vibe\n' > invalid.bin
  preview_unchanged 'binary_files=2'
}

preview_migration_block() {
  preview_setup
  mkdir commands
  printf '<!-- rename-migration:start -->\n/lbwc:vibe\n<!-- rename-migration:end -->\n/lbwc:vibe\n' > commands/init.md
  preview_expect commands/init.md 0 1 commands/init.md
}
