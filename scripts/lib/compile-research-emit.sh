frontmatter_base_commit() {
  awk '
    /^---$/ { if (!started) { started=1; in_fm=1; next } if (in_fm) exit }
    in_fm && index($0, "base_commit:") == 1 {
      val = substr($0, length("base_commit:") + 1)
      sub(/^[[:space:]]*/, "", val)
      print val
      exit
    }
  ' "$1"
}

classify_commit_count() {
  local commit_count="$1"
  if [ "$commit_count" -eq 0 ]; then
    return 0
  elif [ "$commit_count" -le "$STALE_WARN_THRESHOLD" ]; then
    echo "$commit_count" >&2
    return 1
  else
    echo "$commit_count" >&2
    return 2
  fi
}

# Callers read the count from stderr because the messages quote it
check_staleness() {
  local base_commit commit_count
  base_commit=$(frontmatter_base_commit "$1")

  if [ -z "$base_commit" ]; then
    return 2
  fi
  if [ "$base_commit" = "unknown" ]; then
    echo "unknown" >&2
    return 1
  fi
  if ! git rev-parse --verify "$base_commit^{commit}" > /dev/null 2>&1; then
    return 2
  fi

  commit_count=$(git log --oneline "${base_commit}..HEAD" -- . ':!.meridian' ':!CLAUDE.md' 2>/dev/null | wc -l | tr -d ' ')
  classify_commit_count "$commit_count"
}

emit_stale_warning() {
  local file="$1" commit_count_str="$2" base_commit_short
  base_commit_short=$(frontmatter_base_commit "$file" | head -c 8)
  if [ "$commit_count_str" = "unknown" ] || [ "$base_commit_short" = "unknown" ]; then
    echo "${GLYPH_WARNING} Staleness unknown, this research was migrated without a base commit. Verify findings against current code."
    echo "[research] Using research with staleness warning: $(basename "$file") (base_commit unknown; staleness not computed)" >&2
  else
    echo "${GLYPH_WARNING} ${commit_count_str} commits have landed since this research was created (${base_commit_short}..HEAD). Verify findings against current code."
    echo "[research] Using research with staleness warning: $(basename "$file") (${commit_count_str} commits since)" >&2
  fi
  echo ""
  meridian_glyph_file "$file"
}

emit_research() {
  local file="$1"
  local staleness_status commit_count_str

  commit_count_str=$(check_staleness "$file" 2>&1; echo "EXIT:$?") || true
  staleness_status="${commit_count_str##*EXIT:}"
  commit_count_str="${commit_count_str%EXIT:*}"
  commit_count_str=$(echo "$commit_count_str" | tr -d '[:space:]')

  case "$staleness_status" in
    0)
      echo "[research] Using fresh research: $(basename "$file")" >&2
      meridian_glyph_file "$file"
      ;;
    1)
      emit_stale_warning "$file" "$commit_count_str"
      ;;
    2|*)
      echo "[research] Skipping stale research ($(basename "$file")): ${commit_count_str:-unknown} commits since base_commit" >&2
      ;;
  esac
}
