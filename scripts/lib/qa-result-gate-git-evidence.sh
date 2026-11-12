commit_hashes_to_changed_files() {
  local repo_root="${1:-}"
  local commit_hashes="${2:-}"
  [ -n "$repo_root" ] || return 0
  [ -n "$commit_hashes" ] || return 0
  while IFS= read -r commit_hash; do
    commit_hash=$(printf '%s' "$commit_hash" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^['\"]//;s/['\"]$//")
    [ -n "$commit_hash" ] || continue
    git -C "$repo_root" show --name-only --format= "$commit_hash" 2>/dev/null || true
  done <<< "$commit_hashes"
}

commit_hashes_resolve_cleanly() {
  local repo_root="${1:-}"
  local commit_hashes="${2:-}"
  local commit_hash
  [ -n "$repo_root" ] || return 1
  [ -n "$commit_hashes" ] || return 1
  while IFS= read -r commit_hash; do
    commit_hash=$(printf '%s' "$commit_hash" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^['\"]//;s/['\"]$//")
    [ -n "$commit_hash" ] || continue
    git -C "$repo_root" cat-file -e "${commit_hash}^{commit}" 2>/dev/null || return 1
  done <<< "$commit_hashes"
  return 0
}

commit_hashes_are_round_local() {
  local repo_root="${1:-}"
  local round_anchor_commit="${2:-}"
  local commit_hashes="${3:-}"
  local head_commit=""
  local commit_hash
  [ -n "$repo_root" ] || return 1
  [ -n "$round_anchor_commit" ] || return 1
  [ -n "$commit_hashes" ] || return 1
  git -C "$repo_root" cat-file -e "${round_anchor_commit}^{commit}" 2>/dev/null || return 1
  head_commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
  [ -n "$head_commit" ] || return 1
  while IFS= read -r commit_hash; do
    commit_hash=$(printf '%s' "$commit_hash" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^['\"]//;s/['\"]$//")
    [ -n "$commit_hash" ] || continue
    git -C "$repo_root" cat-file -e "${commit_hash}^{commit}" 2>/dev/null || return 1
    [ "$commit_hash" != "$round_anchor_commit" ] || return 1
    git -C "$repo_root" merge-base --is-ancestor "$round_anchor_commit" "$commit_hash" 2>/dev/null || return 1
    git -C "$repo_root" merge-base --is-ancestor "$commit_hash" "$head_commit" 2>/dev/null || return 1
  done <<< "$commit_hashes"
  return 0
}

git_diff_paths_since_commit() {
  local repo_root="${1:-}"
  local anchor_commit="${2:-}"
  [ -n "$repo_root" ] || return 0
  [ -n "$anchor_commit" ] || return 0
  git -C "$repo_root" cat-file -e "${anchor_commit}^{commit}" 2>/dev/null || return 0
  git -C "$repo_root" diff --name-only "$anchor_commit"..HEAD 2>/dev/null || true
}

git_current_worktree_paths() {
  local repo_root="${1:-}"
  [ -n "$repo_root" ] || return 0
  git -C "$repo_root" diff --name-only HEAD 2>/dev/null || true
  git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null || true
}

git_ignored_metadata_worktree_paths() {
  local repo_root="${1:-}"
  local path
  [ -n "$repo_root" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if path_is_metadata_artifact "$path"; then
      printf '%s\n' "$path"
    fi
  done < <(git -C "$repo_root" ls-files --others --ignored --exclude-standard \
    -- .meridian .claude 2>/dev/null || true)
}

commit_is_ancestor_or_same() {
  local repo_root="${1:-}"
  local ancestor_commit="${2:-}"
  local descendant_commit="${3:-}"
  [ -n "$repo_root" ] || return 1
  [ -n "$ancestor_commit" ] || return 1
  [ -n "$descendant_commit" ] || return 1
  git -C "$repo_root" cat-file -e "${ancestor_commit}^{commit}" 2>/dev/null || return 1
  git -C "$repo_root" cat-file -e "${descendant_commit}^{commit}" 2>/dev/null || return 1
  git -C "$repo_root" merge-base --is-ancestor "$ancestor_commit" "$descendant_commit" 2>/dev/null
}

extract_verified_at_commit() {
  local file_path="${1:-}"
  [ -f "$file_path" ] || return 0
  awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^verified_at_commit:/ {
      sub(/^verified_at_commit:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      print
    }
  ' "$file_path" 2>/dev/null
}
