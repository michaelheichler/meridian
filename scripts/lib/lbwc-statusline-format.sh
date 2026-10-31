sanitize_label() {
  printf '%s' "$1" | tr -cd '[:print:]' | cut -c1-64
}

format_tokens() {
  local value="${1:-0}"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  if [ "$value" -ge 1000000 ]; then
    awk -v value="$value" 'BEGIN { printf "%.1fM", value / 1000000 }'
  elif [ "$value" -ge 1000 ]; then
    awk -v value="$value" 'BEGIN { printf "%.1fK", value / 1000 }'
  else
    printf '%s' "$value"
  fi
}

format_duration() {
  local milliseconds="${1:-0}" seconds
  case "$milliseconds" in ''|*[!0-9]*) milliseconds=0 ;; esac
  seconds=$((milliseconds / 1000))
  if [ "$seconds" -ge 3600 ]; then
    printf '%dh %dm' $((seconds / 3600)) $(((seconds % 3600) / 60))
  elif [ "$seconds" -ge 60 ]; then
    printf '%dm %ds' $((seconds / 60)) $((seconds % 60))
  else
    printf '%ds' "$seconds"
  fi
}

progress_bar() {
  local percent="${1:-0}" filled empty color
  case "$percent" in ''|*[!0-9]*) percent=0 ;; esac
  [ "$percent" -gt 100 ] && percent=100
  filled=$((percent / 10))
  [ "$percent" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  empty=$((10 - filled))
  if [ "$percent" -ge 80 ]; then color="$RED"
  elif [ "$percent" -ge 55 ]; then color="$YELLOW"
  else color="$GREEN"
  fi
  printf '%b' "$color"
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%b' "$DIM"
  printf '%*s' "$empty" '' | tr ' ' '.'
  printf '%b' "$RESET"
}

format_reset() {
  local value="${1:-}"
  [ -n "$value" ] || { printf 'unknown'; return; }
  case "$value" in
    *[!0-9]*) sanitize_label "$value" ;;
    *)
      if [ "$(uname)" = "Darwin" ]; then
        date -r "$value" '+%a %H:%M' 2>/dev/null || printf 'unknown'
      else
        date -d "@$value" '+%a %H:%M' 2>/dev/null || printf 'unknown'
      fi
      ;;
  esac
}
