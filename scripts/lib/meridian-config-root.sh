#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/rename-migration.sh"
meridian_migrate_environment

_walk_up_for_meridian_root() {
  local _cwd="$1" _prev
  while [ "$_cwd" != "/" ]; do
    if [ -f "$_cwd/.meridian/config.json" ]; then
      export MERIDIAN_CONFIG_ROOT="$_cwd"
      export MERIDIAN_PLANNING_DIR="$_cwd/.meridian"
      return 0
    fi
    _prev="$_cwd"
    _cwd=$(dirname "$_cwd")
    [ "$_cwd" = "$_prev" ] && break
  done
  return 1
}

_prefer_claude_sidechain_host_root() {
  local _cwd="$1" _probe _parent _grandparent _host

  _probe="$_cwd"
  while [ "$_probe" != "/" ]; do
    case "$(basename "$_probe")" in
      agent-*)
        _parent=$(dirname "$_probe")
        _grandparent=$(dirname "$_parent")
        if [ "$(basename "$_parent")" = "worktrees" ] && [ "$(basename "$_grandparent")" = ".claude" ]; then
          _host=$(dirname "$_grandparent")
          if [ -f "$_host/.meridian/config.json" ]; then
            export MERIDIAN_CONFIG_ROOT="$_host"
            export MERIDIAN_PLANNING_DIR="$_host/.meridian"
            export MERIDIAN_CLAUDE_SIDECHAIN_ROOT="$_probe"
            export MERIDIAN_CLAUDE_SIDECHAIN_HOST_ROOT="$_host"
            return 0
          fi
        fi
        ;;
    esac

    _parent=$(dirname "$_probe")
    [ "$_parent" = "$_probe" ] && break
    _probe="$_parent"
  done

  return 1
}

find_meridian_root() {
  if [ -n "${MERIDIAN_CONFIG_ROOT:-}" ]; then
    export MERIDIAN_CONFIG_ROOT
    export MERIDIAN_PLANNING_DIR="${MERIDIAN_CONFIG_ROOT}/.meridian"
    return 0
  fi

  local _start_dir _cwd_dir
  _cwd_dir=$(pwd -P 2>/dev/null || pwd)

  if [ -n "${1:-}" ]; then
    _prefer_claude_sidechain_host_root "$_cwd_dir" && return 0
    _walk_up_for_meridian_root "$_cwd_dir" && return 0
    if _start_dir=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P 2>/dev/null); then
      _walk_up_for_meridian_root "$_start_dir" && return 0
    else
      _walk_up_for_meridian_root "$_cwd_dir" && return 0
    fi
  else
    _prefer_claude_sidechain_host_root "$_cwd_dir" && return 0
    _walk_up_for_meridian_root "$_cwd_dir" && return 0
  fi

  export MERIDIAN_CONFIG_ROOT="$_cwd_dir"
  export MERIDIAN_PLANNING_DIR="$_cwd_dir/.meridian"
}
