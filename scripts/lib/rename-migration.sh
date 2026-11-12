meridian_migrate_environment() {
  local legacy_name current_name
  while IFS= read -r legacy_name; do
    current_name="MERIDIAN_${legacy_name#LBWC_}"
    if [ "${!current_name+x}" != x ]; then
      printf -v "$current_name" '%s' "${!legacy_name}"
      export "${current_name?}"
    fi
  done < <(compgen -e LBWC_)
}

meridian_migrate_planning() {
  local project_root="${1:-.}"
  local old_dir="$project_root/.lbwc-planning" new_dir="$project_root/.meridian" move_error
  printf -v MERIDIAN_MIGRATION_CONFLICT '%s' 0
  if [ -d "$old_dir" ]; then
    if [ -e "$new_dir" ] || [ -L "$new_dir" ]; then
      printf -v MERIDIAN_MIGRATION_CONFLICT '%s' 1
      printf '%s\n' 'Meridian warning, .lbwc-planning and .meridian both exist, leaving both unchanged.' >&2
    elif [ -L "$old_dir" ]; then
      printf '%s\n' 'Meridian warning, .lbwc-planning is a symlink, leaving it unchanged.' >&2
    elif move_error=$(mv "$old_dir" "$new_dir" 2>&1); then
      printf '%s\n' 'Meridian moved .lbwc-planning to .meridian.' >&2
    else
      move_error="${move_error//$'\n'/ }"
      move_error="${move_error//$'\r'/ }"
      printf 'Meridian could not move .lbwc-planning to .meridian, %s\n' "${move_error:-mv failed without a diagnostic}" >&2
      return 1
    fi
  fi
}
