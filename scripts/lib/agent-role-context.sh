#!/bin/bash
# Both compaction hooks source this file, so their role lists cannot drift apart.

normalize_agent_role() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *coding-dijkstra-critic*) echo coding-dijkstra-critic ;;
    *coding-dijkstra*)        echo coding-dijkstra ;;
    *python-critic*)          echo python-critic ;;
    *python-engineer*)        echo python-engineer ;;
    *web-code-critic*)        echo web-code-critic ;;
    *web-engineer*)           echo web-engineer ;;
    *test-dev*)               echo test-dev ;;
    *qa-author*)              echo qa-author ;;
    *ux-oracle*)              echo ux-oracle ;;
    *architect*)              echo architect ;;
    *debugger*)               echo debugger ;;
    *scout*)                  echo scout ;;
    *lead*)                   echo lead ;;
    *docs*)                   echo docs ;;
    *qa*)                     echo qa ;;
    *) return 1 ;;
  esac
}

role_uses_worktree() {
  case "$1" in
    coding-dijkstra|python-engineer|web-engineer|test-dev|qa-author|debugger|docs) return 0 ;;
    *) return 1 ;;
  esac
}
