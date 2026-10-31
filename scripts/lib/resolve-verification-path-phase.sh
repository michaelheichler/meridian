phase_dir_number() {
  local base
  base=$(basename "${PHASE_DIR%/}")
  [[ "$base" =~ ^[0-9]* ]]
  echo "${BASH_REMATCH[0]}"
}

phase_prefix_from_dir() {
  local phase_num
  phase_num=$(phase_dir_number)
  if [ -n "$phase_num" ] && [[ "$phase_num" =~ ^[0-9]+$ ]]; then
    printf '%02d' "$((10#$phase_num))"
  fi
}

latest_wave_file() {
  local phase_prefix="$1" wave_files
  wave_files=$(ls -1 "$PHASE_DIR/${phase_prefix}-VERIFICATION-wave"*.md 2>/dev/null | (sort -V 2>/dev/null || sort) || true)
  [ -n "$wave_files" ] || return 1
  printf '%s\n' "$wave_files" | tail -1
}

default_verification_path() {
  local phase_num
  phase_num=$(phase_dir_number)
  phase_num="${phase_num:-01}"
  if ! [[ "$phase_num" =~ ^[0-9]+$ ]]; then
    phase_num="01"
  fi
  phase_num=$(printf '%02d' "$((10#$phase_num))")
  echo "$PHASE_DIR/${phase_num}-VERIFICATION.md"
}

phase_level_path() {
  local canonical_name phase_prefix=""

  canonical_name=$(bash "$SCRIPT_DIR/resolve-artifact-path.sh" verification "$PHASE_DIR" 2>/dev/null || true)
  if [ -n "$canonical_name" ]; then
    if [ -f "$PHASE_DIR/$canonical_name" ]; then
      echo "$PHASE_DIR/$canonical_name"
      return 0
    fi
    phase_prefix="${canonical_name%-VERIFICATION.md}"
  fi
  if [ -z "$phase_prefix" ]; then
    phase_prefix=$(phase_prefix_from_dir)
  fi

  if [ -f "$PHASE_DIR/VERIFICATION.md" ]; then
    echo "$PHASE_DIR/VERIFICATION.md"
    return 0
  fi
  if [ -n "$phase_prefix" ] && latest_wave_file "$phase_prefix"; then
    return 0
  fi
  if [ -n "$canonical_name" ]; then
    echo "$PHASE_DIR/$canonical_name"
    return 0
  fi
  default_verification_path
}
