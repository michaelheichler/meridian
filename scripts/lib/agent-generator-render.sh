NAME=""
TARGET=""
NATIVE_TOOLS=""
RENDER_ARGS=()
WORDS_A=()
WORDS_B=()
LOADED_WORDS=()
NAME_MAX_ATTEMPTS=100
LIVE_AGENT_MAX_AGE_SECONDS=3600
DEFAULT_AGENT_CAP=4

WORDLIST_A="${MERIDIAN_AGENT_WORDLIST_A:-$PLUGIN_ROOT/config/agent-generator-adjectives.txt}"
WORDLIST_B="${MERIDIAN_AGENT_WORDLIST_B:-$PLUGIN_ROOT/config/agent-generator-nouns.txt}"

load_words() {
  local file="$1" word
  [ -f "$file" ] || fail "wordlist not found: $file"
  LOADED_WORDS=()
  while IFS= read -r word; do
    LOADED_WORDS+=("$word")
  done < <(grep -E '^[a-z0-9]+$' "$file" || true)
  [ "${#LOADED_WORDS[@]}" -gt 0 ] || fail "wordlist is empty: $file"
}

pick_word() {
  local _pw_pool="$1" _pw_out="$2"
  case "$_pw_pool" in
    A) printf -v "$_pw_out" '%s' "${WORDS_A[RANDOM % ${#WORDS_A[@]}]}" ;;
    B) printf -v "$_pw_out" '%s' "${WORDS_B[RANDOM % ${#WORDS_B[@]}]}" ;;
    *) fail "unknown word pool '$_pw_pool'" ;;
  esac
}

name_is_available() {
  local name="$1" manifest="$2" agents_dir="$3"
  [ ! -e "$agents_dir/$name.md" ] || return 1
  ! jq -e --arg name "$name" '.agents | has($name)' <<< "$manifest" >/dev/null 2>&1
}

choose_name() {
  local role="$1" manifest="$2" agents_dir="$3" left right noun attempt name
  [ -n "${MERIDIAN_AGENT_RANDOM_SEED:-}" ] && RANDOM="$MERIDIAN_AGENT_RANDOM_SEED"
  for ((attempt = 0; attempt < NAME_MAX_ATTEMPTS; attempt++)); do
    pick_word A left
    pick_word A right
    pick_word B noun
    name="meridian-$role-$left-$right-$noun"
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
  printf -v NATIVE_TOOLS '%s' "$tools"
}

renderer_args_for_role() {
  local role="$1" token role_model role_effort role_max_turns override_value
  keyed_get_into role_model ROLE_MODEL "$role"
  keyed_get_into role_effort ROLE_EFFORT "$role"
  keyed_get_into role_max_turns ROLE_MAXTURNS "$role"
  RENDER_ARGS=("NAME=$NAME" "JOB=$JOB" "MAX_TURNS=$role_max_turns")
  [ -n "$role_model" ] || fail "no authoritative model resolved for '$role'"
  RENDER_ARGS+=("MODEL=$role_model" "EFFORT=$role_effort")
  if [ -n "$NATIVE_TEAM_MODE" ]; then
    native_tools_for_role "$role"
    RENDER_ARGS+=("TOOLS=$NATIVE_TOOLS")
  fi
  for token in DESCRIPTION TOOLS DISALLOWED_TOOLS PERMISSION_MODE SKILLS MCP_SERVERS MEMORY BACKGROUND ISOLATION COLOR INITIAL_PROMPT; do
    if keyed_has OVERRIDES "$token"; then
      keyed_get_into override_value OVERRIDES "$token"
      RENDER_ARGS+=("$token=$override_value")
    fi
  done
}

render_and_install_one() {
  local role="$1" tmp name
  name=$(choose_name "$role" "$MANIFEST" "$AGENTS_DIR") || return 1
  printf -v NAME '%s' "$name"
  printf -v TARGET '%s' "$AGENTS_DIR/$NAME.md"
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
