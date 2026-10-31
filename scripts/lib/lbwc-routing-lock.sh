reclaim_stale_lock() {
  local lock_dir="$1" owner_file record pid created token now current
  owner_file="$lock_dir/owner"
  [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
  [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || return 1
  record=$(<"$owner_file")
  IFS=$'\t' read -r pid created token <<< "$record"
  [ "$record" = "$pid"$'\t'"$created"$'\t'"$token" ] || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$created" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$token" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  now=$(date +%s) || return 1
  [ "$created" -le "$now" ] || return 1
  [ $((now - created)) -ge "$LOCK_STALE_AFTER_SECONDS" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  ps -p "$pid" -o pid= >/dev/null 2>&1 && return 1
  [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || return 1
  current=$(<"$owner_file")
  [ "$current" = "$record" ] || return 1
  rm -f -- "$owner_file" 2>/dev/null || return 1
  rmdir "$lock_dir" 2>/dev/null || return 1
}

inherit_transaction_lock() {
  local planning_dir="$1" guard_inode fd_inode
  LOCK_DIR="${LBWC_CONFIG_TRANSACTION_LOCK_DIR:-}"
  LOCK_DIR_IDENTITY="${LBWC_CONFIG_TRANSACTION_LOCK_IDENTITY:-}"
  LOCK_GUARD="${LBWC_CONFIG_TRANSACTION_GUARD:-}"
  LOCK_FD="${LBWC_CONFIG_TRANSACTION_FD:-}"
  LOCK_OWNER_RECORD="${LBWC_CONFIG_TRANSACTION_OWNER:-}"
  [[ "$LOCK_FD" =~ ^[0-9]+$ ]] || fail 'inherited configuration transaction descriptor is invalid'
  [ "${LBWC_CONFIG_TRANSACTION_PLANNING_DIR:-}" = "$planning_dir" ] \
    || fail 'inherited configuration transaction targets another planning directory'
  [ "$LOCK_DIR" = "$planning_dir/.routing.lock" ] \
    || fail 'inherited configuration transaction lock path is invalid'
  [ "$LOCK_GUARD" = "$planning_dir/.routing.lock.guard" ] \
    || fail 'inherited configuration transaction guard path is invalid'
  [ -e "/dev/fd/$LOCK_FD" ] || fail 'inherited configuration transaction descriptor is unavailable'
  guard_inode=$(file_inode "$LOCK_GUARD") || fail 'could not identify inherited configuration transaction guard'
  fd_inode=$(file_inode "/dev/fd/$LOCK_FD") || fail 'could not identify inherited configuration transaction descriptor'
  [ "$guard_inode" = "$fd_inode" ] || fail 'inherited configuration transaction guard changed'
  lock_is_owned || fail 'inherited configuration transaction ownership is invalid'
}

create_lock_token() {
  local token token_status token_detail token_diag_file shell_detail
  token_diag_file=$(mktemp "${TMPDIR:-/tmp}/lbwc-routing-lock-diag.XXXXXX") || fail 'could not create routing lock diagnostic file'
  {
    if token=$(command "$ENV_TOOL" LC_ALL=C "$OD_TOOL" -An -N 16 -tx1 /dev/urandom); then
      token_status=0
    else
      token_status=$?
    fi
  } 2>"$token_diag_file"
  shell_detail=$(<"$token_diag_file")
  rm -f -- "$token_diag_file" 2>/dev/null || true
  token_detail="${token//$'\n'/ }"
  shell_detail="${shell_detail//$'\n'/ }"
  [ -n "$token_detail" ] || token_detail='(no output captured)'
  [ -n "$shell_detail" ] || shell_detail='(no output captured)'
  [ "$token_status" -eq 0 ] \
    || fail "could not create secure routing lock owner token: $OD_TOOL exited $token_status (od stdout: $token_detail) (captured stderr: $shell_detail)"
  token=${token//[[:space:]]/}
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] \
    || fail "routing lock owner token was malformed: $OD_TOOL produced unexpected output (od stdout: $token_detail) (captured stderr: $shell_detail)"
  LOCK_TOKEN="$token"
}

open_lock_guard() {
  local guard_inode fd_inode
  [ ! -L "$LOCK_DIR" ] || fail "symbolic link paths are not allowed: $LOCK_DIR"
  [ ! -e "$LOCK_GUARD" ] || { [ -f "$LOCK_GUARD" ] && [ ! -L "$LOCK_GUARD" ]; } \
    || fail "routing lock guard must be a regular file: $LOCK_GUARD"
  exec 9>> "$LOCK_GUARD" || fail 'could not open routing lock guard'
  [ -f "$LOCK_GUARD" ] && [ ! -L "$LOCK_GUARD" ] || fail "routing lock guard must be a regular file: $LOCK_GUARD"
  guard_inode=$(file_inode "$LOCK_GUARD") || fail 'could not identify routing lock guard'
  fd_inode=$(file_inode "/dev/fd/$LOCK_FD") || fail 'could not identify routing lock guard descriptor'
  [ "$guard_inode" = "$fd_inode" ] || fail 'routing lock guard changed while opening'
}

wait_for_lock_guard() {
  local wait_attempts="$1" attempt guard_held=0
  for ((attempt = 0; attempt < wait_attempts; attempt++)); do
    if invoke_lock_backend "$LOCK_BACKEND" "$LOCK_TOOL" "$LOCK_FD"; then
      guard_held=1
      break
    fi
    sleep 0.01
  done
  [ "$guard_held" -eq 1 ] || fail "could not acquire routing lock: $LOCK_DIR"
}

claim_lock_directory() {
  local token="$1" created
  LOCK_DIR_IDENTITY=$(directory_identity "$LOCK_DIR") || {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    fail 'could not identify routing lock directory'
  }
  created=$(date +%s) || {
    lock_directory_has_identity && rmdir "$LOCK_DIR" 2>/dev/null || true
    fail 'could not record routing lock creation time'
  }
  LOCK_OWNER_RECORD="$$"$'\t'"$created"$'\t'"$token"
  if ! printf '%s\n' "$LOCK_OWNER_RECORD" > "$LOCK_DIR/owner"; then
    if lock_directory_has_identity; then
      rm -f -- "$LOCK_DIR/owner" 2>/dev/null || true
      lock_directory_has_identity && rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    LOCK_OWNER_RECORD=""
    fail 'could not record routing lock ownership'
  fi
  lock_is_owned || fail 'routing lock changed while recording ownership'
  LOCK_HELD=1
}

wait_for_lock_directory() {
  local token="$1" wait_attempts="$2" attempt
  for ((attempt = 0; attempt < wait_attempts; attempt++)); do
    [ ! -L "$LOCK_DIR" ] || fail "symbolic link paths are not allowed: $LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      claim_lock_directory "$token"
      return 0
    fi
    reclaim_stale_lock "$LOCK_DIR" && continue
    sleep 0.01
  done
  fail "could not acquire routing lock: $LOCK_DIR"
}

acquire_config_lock() {
  local planning_dir="$1" wait_attempts
  if [ "$TRANSACTION_ACTIVE" = 1 ]; then
    inherit_transaction_lock "$planning_dir"
    return 0
  fi
  LOCK_DIR="$planning_dir/.routing.lock"
  LOCK_GUARD="$planning_dir/.routing.lock.guard"
  wait_attempts="${LBWC_ROUTING_LOCK_WAIT_ATTEMPTS:-$LOCK_WAIT_ATTEMPTS_DEFAULT}"
  [[ "$wait_attempts" =~ ^[1-9][0-9]*$ ]] || fail 'routing lock wait attempts must be a positive integer'
  [ "$wait_attempts" -le 5000 ] || fail 'routing lock wait attempts exceed the safe bound'
  create_lock_token
  open_lock_guard
  wait_for_lock_guard "$wait_attempts"
  wait_for_lock_directory "$LOCK_TOKEN" "$wait_attempts"
}

export_config_transaction() {
  local planning_dir="$1"
  lock_is_owned || fail 'configuration transaction ownership is invalid'
  export LBWC_CONFIG_TRANSACTION_ACTIVE=1
  export LBWC_CONFIG_TRANSACTION_PLANNING_DIR="$planning_dir"
  export LBWC_CONFIG_TRANSACTION_LOCK_DIR="$LOCK_DIR"
  export LBWC_CONFIG_TRANSACTION_LOCK_IDENTITY="$LOCK_DIR_IDENTITY"
  export LBWC_CONFIG_TRANSACTION_GUARD="$LOCK_GUARD"
  export LBWC_CONFIG_TRANSACTION_FD="$LOCK_FD"
  export LBWC_CONFIG_TRANSACTION_OWNER="$LOCK_OWNER_RECORD"
}

assert_no_pending_model_refresh() {
  local planning_dir="$1" pending="$1/.lbwc-model-refresh.pending"
  [ ! -e "$pending" ] && [ ! -L "$pending" ] \
    || fail "pending model refresh requires recovery: $pending"
}

run_config_transaction() {
  local planning_dir="$1"
  shift
  [ "$#" -gt 0 ] || fail 'configuration transaction requires a command'
  acquire_config_lock "$planning_dir"
  assert_no_pending_model_refresh "$planning_dir"
  export_config_transaction "$planning_dir"
  command "$@"
}
