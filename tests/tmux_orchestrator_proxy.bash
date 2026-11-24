#!/usr/bin/env bash
set -u
if [ "${1:-}" = -L ]; then
  [ "${2:-}" = "$MERIDIAN_TEST_TMUX_SERVER" ] || exit 1
  shift 2
fi
case "${1:-}" in
  new-session|split-window)
    : "${MERIDIAN_TEST_CHILD_PATH:?fixture child PATH is required}"
    : "${MERIDIAN_TEST_CHILD_SHELL:?fixture child shell is required}"
    [ -x "$MERIDIAN_TEST_CHILD_SHELL" ] || exit 1
    ;;
esac
if [ "$1" = kill-pane ] && [ -n "${MERIDIAN_TEST_PANE_DELAY:-}" ]; then
  printf '%s\n' "$3" > "$MERIDIAN_TEST_PANE_DELAY"
  printf '%s\n' 0 > "$MERIDIAN_TEST_PANE_DELAY.count"
  exit 0
fi
if [ "$1" = display-message ] && [ -n "${MERIDIAN_TEST_PANE_DELAY:-}" ] && [ -f "$MERIDIAN_TEST_PANE_DELAY" ]; then
  delayed_pane=$(cat "$MERIDIAN_TEST_PANE_DELAY")
  if [ "$4" = "$delayed_pane" ]; then
    count=$(cat "$MERIDIAN_TEST_PANE_DELAY.count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$MERIDIAN_TEST_PANE_DELAY.count"
    if [ "$count" -ge "${MERIDIAN_TEST_PANE_DELAY_PROBES:-3}" ]; then
      "$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null kill-pane -t "$delayed_pane"
      rm -f "$MERIDIAN_TEST_PANE_DELAY"
      exit 1
    fi
  fi
fi
if [ "$1" = "split-window" ] && [ -n "${MERIDIAN_TEST_SPLIT_COUNTER:-}" ]; then
  count=0
  [ -f "$MERIDIAN_TEST_SPLIT_COUNTER" ] && count=$(cat "$MERIDIAN_TEST_SPLIT_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$MERIDIAN_TEST_SPLIT_COUNTER"
  [ "$count" -lt 2 ] || exit 1
fi
if [ "$1" = "split-window" ] && [ -n "${MERIDIAN_TEST_FAST_CHILD_ENV:-}" ]; then
  arguments=("$@")
  : > "$MERIDIAN_TEST_FAST_CHILD_ENV"
  for argument in "$@"; do
    case "$argument" in
      MERIDIAN_TMUX_AGENT=*|MERIDIAN_TMUX_CONTROL_ROOT=*|MERIDIAN_TMUX_AGENT_ID=*|MERIDIAN_TMUX_CONTRACT_ID=*)
        printf '%s\n' "$argument" >> "$MERIDIAN_TEST_FAST_CHILD_ENV"
        ;;
    esac
  done
  pane_id=$("$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null "${arguments[0]}" \
    -e "PATH=$MERIDIAN_TEST_CHILD_PATH" \
    -e "MERIDIAN_TEST_FAST_CHILD_ENV=$MERIDIAN_TEST_FAST_CHILD_ENV" \
    -e "MERIDIAN_TEST_FAST_CHILD_STATUS=$MERIDIAN_TEST_FAST_CHILD_STATUS" \
    -e "MERIDIAN_TEST_FAST_CHILD_OUTPUT=$MERIDIAN_TEST_FAST_CHILD_OUTPUT" \
    -e "MERIDIAN_TEST_FAST_CHILD_READY=$MERIDIAN_TEST_FAST_CHILD_READY" \
    -e "MERIDIAN_TEST_FAST_CHILD_RELEASE=$MERIDIAN_TEST_FAST_CHILD_RELEASE" \
    -e "MERIDIAN_TEST_FAST_CHILD_PANE=$MERIDIAN_TEST_FAST_CHILD_PANE" \
    -e "MERIDIAN_TEST_FAST_CHILD_STARTED=$MERIDIAN_TEST_FAST_CHILD_STARTED" \
    -e "MERIDIAN_TEST_FAST_CHILD_EXIT=$MERIDIAN_TEST_FAST_CHILD_EXIT" \
    -e "MERIDIAN_TEST_SESSION_START=$MERIDIAN_TEST_SESSION_START" \
    -e "MERIDIAN_TEST_FAST_CHILD_SESSION=$MERIDIAN_TEST_FAST_CHILD_SESSION" \
    "${arguments[@]:1}" "$MERIDIAN_TEST_CHILD_SHELL" --noprofile --norc) || exit 1
  printf '%s\n' "$pane_id"
  exit 0
fi
if [ "$1" = "send-keys" ] && [ -n "${MERIDIAN_TEST_SEND_KEYS_COUNTER:-}" ]; then
  count=0
  [ -f "$MERIDIAN_TEST_SEND_KEYS_COUNTER" ] && count=$(cat "$MERIDIAN_TEST_SEND_KEYS_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$MERIDIAN_TEST_SEND_KEYS_COUNTER"
  [ "$count" -le "${MERIDIAN_TEST_FAIL_SEND_KEYS_AFTER:-0}" ] || exit 1
fi
if [ "$1" = "split-window" ] && [ -n "${MERIDIAN_TEST_LAYOUT_AFTER_SPLIT:-}" ]; then
  printf '{"tmux":{"layout":"%s"}}\n' "$MERIDIAN_TEST_LAYOUT_AFTER_SPLIT" > "$MERIDIAN_TEST_CONFIG_PATH"
fi
if [ "$1" = "select-layout" ] && [ -n "${MERIDIAN_TEST_SELECT_LAYOUT_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$MERIDIAN_TEST_SELECT_LAYOUT_LOG"
fi
if [ "$1" = "select-layout" ] && [ "${MERIDIAN_TEST_FAIL_LAYOUT:-0}" = 1 ]; then
  exit 1
fi
if [ "$1" = select-layout ] && [ "${MERIDIAN_TEST_FAIL_PANE_LAYOUT:-0}" = 1 ] && [[ "$3" == %* ]]; then
  exit 1
fi
if [ "$1" = select-pane ] && [ "$#" = 3 ] && [ -n "${MERIDIAN_TEST_FOCUS_LOG:-}" ]; then
  "$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null "$@" || exit 1
  target=$("$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null display-message -p -t "$3" '#{pane_id}')
  selected=$("$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null list-panes -t "$3" -F '#{pane_id} #{pane_active}' | awk '$2 == 1 {print $1}')
  geometry=$("$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null list-panes -t "$3" -F '#{pane_top} #{pane_width}')
  aligned=false
  if awk 'NR == 1 {top=$1; width=$2} $1 != top || $2 < width-1 || $2 > width+1 {exit 1}' <<<"$geometry"; then
    aligned=true
  fi
  printf '{"target":"%s","active":"%s","aligned":%s}\n' "$target" "$selected" "$aligned" >> "$MERIDIAN_TEST_FOCUS_LOG"
  exit 0
fi
case "$1" in
  new-session|split-window)
    exec "$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null "$@" /usr/bin/env "PATH=$MERIDIAN_TEST_CHILD_PATH" "$MERIDIAN_TEST_CHILD_SHELL" --noprofile --norc
    ;;
esac
exec "$MERIDIAN_TEST_TMUX_BINARY" -L "$MERIDIAN_TEST_TMUX_SERVER" -f /dev/null "$@"
