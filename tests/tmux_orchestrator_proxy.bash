#!/usr/bin/env bash
set -u
if [ "${1:-}" = -L ]; then
  [ "${2:-}" = "$LBWC_TEST_TMUX_SERVER" ] || exit 1
  shift 2
fi
case "${1:-}" in
  new-session|split-window)
    : "${LBWC_TEST_CHILD_PATH:?fixture child PATH is required}"
    : "${LBWC_TEST_CHILD_SHELL:?fixture child shell is required}"
    [ -x "$LBWC_TEST_CHILD_SHELL" ] || exit 1
    ;;
esac
if [ "$1" = "split-window" ] && [ -n "${LBWC_TEST_SPLIT_COUNTER:-}" ]; then
  count=0
  [ -f "$LBWC_TEST_SPLIT_COUNTER" ] && count=$(cat "$LBWC_TEST_SPLIT_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$LBWC_TEST_SPLIT_COUNTER"
  [ "$count" -lt 2 ] || exit 1
fi
if [ "$1" = "split-window" ] && [ -n "${LBWC_TEST_FAST_CHILD_ENV:-}" ]; then
  arguments=("$@")
  : > "$LBWC_TEST_FAST_CHILD_ENV"
  for argument in "$@"; do
    case "$argument" in
      LBWC_TMUX_AGENT=*|LBWC_TMUX_CONTROL_ROOT=*|LBWC_TMUX_AGENT_ID=*|LBWC_TMUX_CONTRACT_ID=*)
        printf '%s\n' "$argument" >> "$LBWC_TEST_FAST_CHILD_ENV"
        ;;
    esac
  done
  pane_id=$("$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null "${arguments[0]}" \
    -e "PATH=$LBWC_TEST_CHILD_PATH" \
    -e "LBWC_TEST_FAST_CHILD_ENV=$LBWC_TEST_FAST_CHILD_ENV" \
    -e "LBWC_TEST_FAST_CHILD_STATUS=$LBWC_TEST_FAST_CHILD_STATUS" \
    -e "LBWC_TEST_FAST_CHILD_OUTPUT=$LBWC_TEST_FAST_CHILD_OUTPUT" \
    -e "LBWC_TEST_FAST_CHILD_READY=$LBWC_TEST_FAST_CHILD_READY" \
    -e "LBWC_TEST_FAST_CHILD_RELEASE=$LBWC_TEST_FAST_CHILD_RELEASE" \
    -e "LBWC_TEST_FAST_CHILD_PANE=$LBWC_TEST_FAST_CHILD_PANE" \
    -e "LBWC_TEST_FAST_CHILD_STARTED=$LBWC_TEST_FAST_CHILD_STARTED" \
    -e "LBWC_TEST_FAST_CHILD_EXIT=$LBWC_TEST_FAST_CHILD_EXIT" \
    -e "LBWC_TEST_SESSION_START=$LBWC_TEST_SESSION_START" \
    "${arguments[@]:1}" "$LBWC_TEST_CHILD_SHELL" --noprofile --norc) || exit 1
  printf '%s\n' "$pane_id"
  exit 0
fi
if [ "$1" = "send-keys" ] && [ -n "${LBWC_TEST_SEND_KEYS_COUNTER:-}" ]; then
  count=0
  [ -f "$LBWC_TEST_SEND_KEYS_COUNTER" ] && count=$(cat "$LBWC_TEST_SEND_KEYS_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$LBWC_TEST_SEND_KEYS_COUNTER"
  [ "$count" -le "${LBWC_TEST_FAIL_SEND_KEYS_AFTER:-0}" ] || exit 1
fi
if [ "$1" = "split-window" ] && [ -n "${LBWC_TEST_LAYOUT_AFTER_SPLIT:-}" ]; then
  printf '{"tmux":{"layout":"%s"}}\n' "$LBWC_TEST_LAYOUT_AFTER_SPLIT" > "$LBWC_TEST_CONFIG_PATH"
fi
if [ "$1" = "select-layout" ] && [ -n "${LBWC_TEST_SELECT_LAYOUT_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$LBWC_TEST_SELECT_LAYOUT_LOG"
fi
if [ "$1" = "select-layout" ] && [ "${LBWC_TEST_FAIL_LAYOUT:-0}" = 1 ]; then
  exit 1
fi
if [ "$1" = select-layout ] && [ "${LBWC_TEST_FAIL_PANE_LAYOUT:-0}" = 1 ] && [[ "$3" == %* ]]; then
  exit 1
fi
if [ "$1" = select-pane ] && [ "$#" = 3 ] && [ -n "${LBWC_TEST_FOCUS_LOG:-}" ]; then
  "$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null "$@" || exit 1
  target=$("$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null display-message -p -t "$3" '#{pane_id}')
  selected=$("$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null list-panes -t "$3" -F '#{pane_id} #{pane_active}' | awk '$2 == 1 {print $1}')
  geometry=$("$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null list-panes -t "$3" -F '#{pane_top} #{pane_width}')
  aligned=false
  if awk 'NR == 1 {top=$1; width=$2} $1 != top || $2 < width-1 || $2 > width+1 {exit 1}' <<<"$geometry"; then
    aligned=true
  fi
  printf '{"target":"%s","active":"%s","aligned":%s}\n' "$target" "$selected" "$aligned" >> "$LBWC_TEST_FOCUS_LOG"
  exit 0
fi
case "$1" in
  new-session|split-window)
    exec "$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null "$@" /usr/bin/env "PATH=$LBWC_TEST_CHILD_PATH" "$LBWC_TEST_CHILD_SHELL" --noprofile --norc
    ;;
esac
exec "$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" -f /dev/null "$@"
