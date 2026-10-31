NAME=""
TARGET=""
NATIVE_TOOLS=""
RENDER_ARGS=()
WORDS_A=()
WORDS_B=()
NAME_MAX_ATTEMPTS=100
LIVE_AGENT_MAX_AGE_SECONDS=3600
DEFAULT_AGENT_CAP=4

WORDLIST_A="${LBWC_AGENT_WORDLIST_A:-$PLUGIN_ROOT/config/agent-generator-adjectives.txt}"
WORDLIST_B="${LBWC_AGENT_WORDLIST_B:-$PLUGIN_ROOT/config/agent-generator-nouns.txt}"

load_words() {
  local file="$1" target="$2"
  local -n words="$target"
  [ -f "$file" ] || fail "wordlist not found: $file"
  mapfile -t words < <(grep -E '^[a-z0-9]+$' "$file" || true)
  [ "${#words[@]}" -gt 0 ] || fail "wordlist is empty: $file"
}

pick_word() {
  local array_name="$1" out_var="$2"
  local -n word_array="$array_name"
  printf -v "$out_var" '%s' "${word_array[RANDOM % ${#word_array[@]}]}"
}

name_is_available() {
  local name="$1" manifest="$2" agents_dir="$3"
  [ ! -e "$agents_dir/$name.md" ] || return 1
  ! jq -e --arg name "$name" '.agents | has($name)' <<< "$manifest" >/dev/null 2>&1
}

choose_name() {
  local role="$1" manifest="$2" agents_dir="$3" left right noun attempt name
  [ -n "${LBWC_AGENT_RANDOM_SEED:-}" ] && RANDOM="$LBWC_AGENT_RANDOM_SEED"
  for ((attempt = 0; attempt < NAME_MAX_ATTEMPTS; attempt++)); do
    pick_word WORDS_A left
    pick_word WORDS_A right
    pick_word WORDS_B noun
    name="lbwc-$role-$left-$right-$noun"
    if name_is_available "$name" "$manifest" "$agents_dir"; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  fail "could not find a collision-free generated name"
}

native_tools_for_role() {
  local role="$1" coordination_tool tools
  tools=$(jq -r --arg role "$role" '.[$role].tools // ""' "$TEMPLATE_DEFAULTS")
  if [ -z "$tools" ]; then
    case "$role" in
      *critic|qa|ux-oracle|deviq) tools="Read, Grep, Glob" ;;
      *) tools="Read, Grep, Glob, Write, Edit" ;;
    esac
  fi
  for coordination_tool in SendMessage TaskGet TaskList TaskUpdate; do
    case ",$tools," in *",$coordination_tool,"*) ;; *) tools="$tools, $coordination_tool" ;; esac
  done
  declare -g NATIVE_TOOLS="$tools"
}

renderer_args_for_role() {
  local role="$1" token
  RENDER_ARGS=("NAME=$NAME" "JOB=$JOB" "MAX_TURNS=${ROLE_MAXTURNS[$role]}")
  [ -n "${ROLE_MODEL[$role]}" ] || fail "no authoritative model resolved for '$role'"
  RENDER_ARGS+=("MODEL=${ROLE_MODEL[$role]}" "EFFORT=${ROLE_EFFORT[$role]}")
  if [ -n "$NATIVE_TEAM_MODE" ]; then
    native_tools_for_role "$role"
    RENDER_ARGS+=("TOOLS=$NATIVE_TOOLS")
  fi
  for token in DESCRIPTION TOOLS DISALLOWED_TOOLS PERMISSION_MODE SKILLS MCP_SERVERS MEMORY BACKGROUND ISOLATION COLOR INITIAL_PROMPT; do
    if [ "${OVERRIDES[$token]+set}" = set ]; then
      RENDER_ARGS+=("$token=${OVERRIDES[$token]}")
    fi
  done
}

render_and_install_one() {
  local role="$1" tmp name
  name=$(choose_name "$role" "$MANIFEST" "$AGENTS_DIR") || return 1
  declare -g NAME="$name"
  declare -g TARGET="$AGENTS_DIR/$NAME.md"
  renderer_args_for_role "$role"
  tmp="${TARGET}.tmp.${BASHPID:-$$}"
  if ! CONTRACT_RESOLVED_BACKEND="$CONTRACT_RESOLVED_BACKEND" bash "$SCRIPT_DIR/render-agent-template.sh" "$role" "${RENDER_ARGS[@]}" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$TARGET" || { rm -f "$tmp"; return 1; }
  if [ -n "$NATIVE_TEAM_MODE" ]; then
    cp "$TARGET" "$CONTROL_ROOT/generated-agents/$NAME.md"
  fi
}
