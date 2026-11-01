#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  REPO="$TEST_TEMP_DIR/repo"
  setup_unrelated_git_repo "$REPO"
  cd "$REPO" || return 1
  SCRIPT="$SCRIPTS_DIR/debug-skill-enrichment.sh"
  mkdir -p src/Models legacy ui
  printf 'import SwiftData\n@Model\nfinal class TodoStore {}\nlet context: ModelContext\n' > src/Models/TodoStore.swift
  printf 'import CoreData\nlet container: NSPersistentContainer\n' > legacy/CoreDataStack.swift
  local name
  for name in One Two Three Four; do
    printf 'let owner = WidgetManager()\n' > "ui/Widget$name.swift"
  done
  printf '%s\n' 'import SwiftData' '@Model' 'ModelContext' 'ModelContainer' 'FetchDescriptor' 'VersionedSchema' > Persistence.swift
  git add -A
  git commit -qm fixtures
  await_git_ai
}

teardown() {
  cd "$PROJECT_ROOT" || true
  teardown_temp_dir
}

enrich_from_stdin() {
  printf '%s' "$1" | bash "$SCRIPT"
}

enrichment_summary() {
  printf '%s' "$output" | jq -r '"\(.status) triggered=\(.triggered) tokens=\(.tokens | join(",")) files=\(.matched_files | join(",")) markers=\(.markers | join(","))"' 2>&1
}

expect_enrichment() {
  local label="$1" want="$2" got
  expect_case "$label" 0
  got=$(enrichment_summary)
  [ "$got" = "$want" ] || record_case_failure "$label" "got=[$got] want=[$want]"
}

expect_json_field() {
  local label="$1" field="$2" want="$3" got
  got=$(printf '%s' "$output" | jq -r "$field" 2>&1)
  [ "$got" = "$want" ] || record_case_failure "$label" "$field got=[$got] want=[$want]"
}

@test "enrichment returns at most three likely files and five persistence markers for concrete cues, and a bounded no-op otherwise" {
  reset_case_failures

  run enrich_from_stdin ""
  expect_enrichment empty-stdin "no_signal triggered=false tokens= files= markers="
  expect_json_field empty-stdin .message "Empty query"

  run bash "$SCRIPT" $'  \n\t '
  expect_enrichment whitespace-argument "no_signal triggered=false tokens= files= markers="

  run bash "$SCRIPT" "the app is slow sometimes"
  expect_enrichment no-concrete-cue "no_signal triggered=false tokens= files= markers="
  expect_json_field no-concrete-cue .message "No concrete symbol, service, type, or file cue detected"

  run bash "$SCRIPT" "AlphaStore BetaStore GammaStore DeltaStore all fail"
  expect_enrichment cue-without-files "no_match triggered=true tokens=AlphaStore,BetaStore,GammaStore files= markers="

  run bash "$SCRIPT" "TodoStore crashes when saving"
  expect_enrichment camel-case-type "ok triggered=true tokens=TodoStore files=src/Models/TodoStore.swift markers=import SwiftData,@Model,ModelContext"
  expect_json_field camel-case-type .summary "Bounded enrichment matched TodoStore -> src/Models/TodoStore.swift; markers: import SwiftData, @Model, ModelContext"
  expect_json_field camel-case-type .source "bounded_enrichment"

  run enrich_from_stdin $'(legacy/CoreDataStack.swift fails\nafter the migration'
  expect_enrichment multiline-path-on-stdin "ok triggered=true tokens=legacy/CoreDataStack.swift files=legacy/CoreDataStack.swift markers=import CoreData,NSPersistentContainer"

  run bash "$SCRIPT" "TodoStore fails in src/Models/TodoStore.swift"
  expect_enrichment two-cues-one-file "ok triggered=true tokens=TodoStore,src/Models/TodoStore.swift files=src/Models/TodoStore.swift markers=import SwiftData,@Model,ModelContext"

  run bash "$SCRIPT" "WidgetManager leaks"
  expect_enrichment many-files-capped "ok triggered=true tokens=WidgetManager files=ui/WidgetFour.swift,ui/WidgetOne.swift,ui/WidgetThree.swift markers="
  expect_json_field many-files-capped .summary "Bounded enrichment matched WidgetManager -> ui/WidgetFour.swift, ui/WidgetOne.swift, ui/WidgetThree.swift"

  run bash "$SCRIPT" "Persistence.swift breaks"
  expect_enrichment many-markers-capped "ok triggered=true tokens=Persistence.swift files=Persistence.swift markers=import SwiftData,@Model,ModelContext,ModelContainer,FetchDescriptor"

  mkdir -p "$TEST_TEMP_DIR/nojq-bin"
  ln -s "$(command -v bash)" "$TEST_TEMP_DIR/nojq-bin/bash"
  run env PATH="$TEST_TEMP_DIR/nojq-bin" bash "$SCRIPT" "TodoStore crashes"
  expect_case without-jq 0 '{"status":"error","triggered":false,"message":"jq unavailable"}'

  assert_no_case_failures
}
