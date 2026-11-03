context_library_absent() {
  local guard="$1" shadow="$TEST_TEMP_DIR/context-library-absent-$1"
  mkdir -p "$shadow/lib"
  cp "$SCRIPTS_DIR/$guard.sh" "$shadow/$guard.sh"
  cp -R "$SCRIPTS_DIR/lib/." "$shadow/lib/"
  rm "$shadow/lib/tmux-agent-context.sh"
  run bash "$shadow/$guard.sh" <<< '{}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Blocked:"*"tmux agent context library"* ]]
}
