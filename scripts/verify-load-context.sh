#!/bin/bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
set -u

case "${1:-}" in
state)
head -40 .meridian/STATE.md 2>/dev/null || echo "No state found"
;;
phases)
ls .meridian/phases/ 2>/dev/null || echo "No phases directory"
;;
phase-state)
SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"
P="/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
PD=""
_refresh_phase_detect() {
  local resolver root
  resolver="$L/scripts/resolve-plugin-root.sh"
  if [ ! -f "$resolver" ]; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-plugin-root.sh" ]; then
      resolver="${CLAUDE_PLUGIN_ROOT}/scripts/resolve-plugin-root.sh"
    else
      return 1
    fi
  fi
  root=$(bash "$resolver" --require-script phase-detect.sh 2>/dev/null) || return 1
  PD=$(bash "$root/scripts/phase-detect.sh" 2>/dev/null) || PD=""
  if [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] || [ "$PD" = "phase_detect_error=true" ]; then
    return 1
  fi
  printf '%s' "$PD" > "$P"
  return 0
}
if ! _refresh_phase_detect; then
  PD="phase_detect_error=true"
  printf '%s\n' "$PD" > "$P"
fi
[ -f "$P" ] && PD=$(cat "$P")
if [ -n "$(printf '%s' "$PD" | tr -d '[:space:]')" ] && [ "$PD" != "phase_detect_error=true" ]; then
  printf '%s' "$PD"
else
  echo "phase_detect_error=true"
fi
;;
compact)
bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}/scripts/suggest-compact.sh" verify 2>/dev/null || true
;;
verify-context)
SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
P="/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
PD=""
[ -f "$P" ] && PD=$(cat "$P")
if [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] || [ "$PD" = "phase_detect_error=true" ]
then
  echo "verify_target_slug=unavailable"
else
  STATE=$(printf '%s' "$PD" | grep '^next_phase_state=' | head -1 | cut -d= -f2)
  SLUG=$(printf '%s' "$PD" | grep '^next_phase_slug=' | head -1 | cut -d= -f2)
  FU_SLUG=$(printf '%s' "$PD" | grep '^first_unverified_slug=' | head -1 | cut -d= -f2)
  if [ "$STATE" = "needs_reverification" ] || [ "$STATE" = "needs_verification" ]
  then
    TARGET="$SLUG"
  else
    TARGET="${FU_SLUG:-$SLUG}"
  fi
  echo "verify_target_slug=$TARGET"
fi
echo "verify_context=deferred_until_target_resolution"
;;
uat-resume)
SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"
P="/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
PD=""
_refresh_phase_detect() {
  local resolver root
  resolver="$L/scripts/resolve-plugin-root.sh"
  if [ ! -f "$resolver" ]; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-plugin-root.sh" ]; then
      resolver="${CLAUDE_PLUGIN_ROOT}/scripts/resolve-plugin-root.sh"
    else
      return 1
    fi
  fi
  root=$(bash "$resolver" --require-script phase-detect.sh 2>/dev/null) || return 1
  PD=$(bash "$root/scripts/phase-detect.sh" 2>/dev/null) || PD=""
  if [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] || [ "$PD" = "phase_detect_error=true" ]; then
    return 1
  fi
  printf '%s' "$PD" > "$P"
  return 0
}
if ! _refresh_phase_detect; then
  PD="phase_detect_error=true"
  printf '%s\n' "$PD" > "$P"
fi
[ -f "$P" ] && PD=$(cat "$P")
if [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] || [ "$PD" = "phase_detect_error=true" ]; then
  echo "uat_resume=unavailable"
else
  STATE=$(printf '%s' "$PD" | grep '^next_phase_state=' | head -1 | cut -d= -f2)
  SLUG=$(printf '%s' "$PD" | grep '^next_phase_slug=' | head -1 | cut -d= -f2)
  FU_SLUG=$(printf '%s' "$PD" | grep '^first_unverified_slug=' | head -1 | cut -d= -f2)
  if [ "$STATE" = "needs_reverification" ] || [ "$STATE" = "needs_verification" ]; then TARGET="$SLUG"; else TARGET="${FU_SLUG:-$SLUG}"; fi
  PDIR=".meridian/phases/$TARGET"
  if [ -n "$TARGET" ] && [ -d "$PDIR" ] && [ -L "$L" ] && [ -f "$L/scripts/extract-uat-resume.sh" ]; then
    echo "uat_resume_target_slug=$TARGET"
    bash "$L/scripts/extract-uat-resume.sh" "$PDIR" 2>/dev/null || echo "uat_resume=error"
  else
    echo "uat_resume=unavailable"
  fi
fi
;;
qa-summary)
bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}/scripts/extract-verified-items.sh" .meridian/phases/*/ 2>/dev/null || true
;;
*)
  printf "Usage: %s <state|phases|phase-state|compact|verify-context|uat-resume|qa-summary>\n" "$0" >&2
  exit 2
  ;;
esac
