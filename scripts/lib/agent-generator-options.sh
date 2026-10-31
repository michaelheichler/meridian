declare -A OVERRIDES=()
WRITE_ALLOWANCES=()
WRITE_CAPABILITIES=()
ROLE_WRITE_ALLOWANCE_ROLES=()
ROLE_WRITE_ALLOWANCE_PATHS=()
ROLE_WRITE_CAPABILITY_ROLES=()
ROLE_WRITE_CAPABILITY_VALUES=()
CONTROL_ROOT_ARG=""
JOB=""
PAIR_ROLE_ARG=""
EXCLUSIVE_MODE=""
CONTRACT_PATH=""
TASK_ID=""
EXECUTION_BACKEND_OVERRIDE=""
SCOPED_ROLE=""
SCOPED_VALUE=""
OPTION_KEY=""
OPTION_VALUE=""
OPTION_CONSUMED=0

option_token() { agent_field_token "$1"; }

split_role_scoped() {
  local option="$1" value="$2"
  SCOPED_ROLE="${value%%:*}"
  SCOPED_VALUE="${value#*:}"
  [ "$SCOPED_ROLE" != "$value" ] && [ -n "$SCOPED_ROLE" ] && [ -n "$SCOPED_VALUE" ] || fail "invalid $option '$value'"
}

add_role_write_allowance() {
  split_role_scoped --role-write-allowance "$1"
  ROLE_WRITE_ALLOWANCE_ROLES+=("$SCOPED_ROLE")
  ROLE_WRITE_ALLOWANCE_PATHS+=("$SCOPED_VALUE")
}

add_role_write_capability() {
  split_role_scoped --role-write-capability "$1"
  ROLE_WRITE_CAPABILITY_ROLES+=("$SCOPED_ROLE")
  ROLE_WRITE_CAPABILITY_VALUES+=("$SCOPED_VALUE")
}

set_override_option() {
  local key="$1" value="$2" token
  token=$(option_token "$key") || fail "unknown option '$key'"
  OVERRIDES["$token"]="$value"
}

apply_option() {
  local key="$1" value="$2"
  case "$key" in
    --job) JOB="$value" ;;
    --contract|--contract-input) CONTRACT_PATH="$value" ;;
    --task-id|--task-identity) TASK_ID="$value" ;;
    --execution-backend) EXECUTION_BACKEND_OVERRIDE="$value" ;;
    --control-root) CONTROL_ROOT_ARG="$value" ;;
    --pair-role) PAIR_ROLE_ARG="$value" ;;
    --write-allowance) WRITE_ALLOWANCES+=("$value") ;;
    --write-capability|--capability) WRITE_CAPABILITIES+=("$value") ;;
    --role-write-allowance) add_role_write_allowance "$value" ;;
    --role-write-capability) add_role_write_capability "$value" ;;
    *) set_override_option "$key" "$value" ;;
  esac
}

split_option_argument() {
  local argument="$1"
  if [[ "$argument" == --*=* ]]; then
    OPTION_KEY="${argument%%=*}"
    OPTION_VALUE="${argument#*=}"
    OPTION_CONSUMED=0
  else
    OPTION_KEY="$argument"
    OPTION_CONSUMED=1
  fi
}

parse_options() {
  local argument
  while [ "$#" -gt 0 ]; do
    argument="$1"
    shift
    if [ "$argument" = "--exclusive" ]; then
      EXCLUSIVE_MODE=1
      continue
    fi
    split_option_argument "$argument"
    if [ "$OPTION_CONSUMED" = 1 ]; then
      [ "$#" -gt 0 ] || fail "missing value for $OPTION_KEY"
      OPTION_VALUE="$1"
      shift
    fi
    apply_option "$OPTION_KEY" "$OPTION_VALUE"
  done
}

check_required_options() {
  [ -n "$JOB" ] || fail "--job is required"
  [ -n "$CONTRACT_PATH" ] || fail "--contract is required for generated LBWC agents"
  [ -n "$TASK_ID" ] || fail "--task-id is required for generated LBWC agents"
  [ -z "$PAIR_ROLE_ARG" ] || [ -n "$PAIR_MODE" ] || fail "--pair-role is only valid with --pair"
  [ -z "$PAIR_ROLE_ARG" ] || [ -z "$TRIO_MODE" ] || fail "--pair-role is not valid with --trio"
}

check_native_team_overrides() {
  local native_token
  [ -n "$NATIVE_TEAM_MODE" ] || return 0
  for native_token in MODEL EFFORT MAX_TURNS TOOLS DISALLOWED_TOOLS DESCRIPTION PERMISSION_MODE SKILLS MCP_SERVERS MEMORY BACKGROUND ISOLATION COLOR INITIAL_PROMPT; do
    [ "${OVERRIDES[$native_token]+set}" = set ] || continue
    fail "native-team definition overrides are not allowed: $native_token"
  done
}

task_write_path_is_safe() {
  case "$1" in
    ''|/*|.|./*|*/.|..|../*|*/..|*/../*|*'//'*) return 1 ;;
    *$'\n'*|*$'\r'*) return 1 ;;
    */) return 1 ;;
  esac
}

test_write_path_is_exact() {
  case "$1" in
    tests/*)
      case "$1" in
        *['*?[']*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

check_write_allowance_paths() {
  local write_allowance
  for write_allowance in "${WRITE_ALLOWANCES[@]}"; do
    task_write_path_is_safe "$write_allowance" || fail "invalid --write-allowance '$write_allowance'"
  done
  if [ "$CONTRACT_SCHEMA_VERSION" = "3" ] && [ "${#WRITE_ALLOWANCES[@]}" -gt 0 ]; then
    fail "schema 3 contracts require typed write capabilities"
  fi
}

check_role_write_allowance() {
  local index="$1" scoped_role scoped_path
  scoped_role="${ROLE_WRITE_ALLOWANCE_ROLES[$index]}"
  scoped_path="${ROLE_WRITE_ALLOWANCE_PATHS[$index]}"
  [ -n "$TRIO_MODE" ] || fail "--role-write-allowance is only valid with --trio"
  [ "$scoped_role" = "test-dev" ] || fail "--role-write-allowance is only valid for test-dev in a trio"
  role_is_on_team "$scoped_role" || fail "--role-write-allowance role is not in this team: '$scoped_role'"
  task_write_path_is_safe "$scoped_path" || fail "invalid --role-write-allowance '$scoped_role:$scoped_path'"
  test_write_path_is_exact "$scoped_path" || fail "--role-write-allowance for test-dev must be an exact repository test path: '$scoped_path'"
}

check_write_scope() {
  local index
  if role_is_critic "$ROLE" && [ "${#WRITE_ALLOWANCES[@]}" -gt 0 ]; then
    fail "--write-allowance is not valid for a critic"
  fi
  for index in "${!ROLE_WRITE_ALLOWANCE_ROLES[@]}"; do
    check_role_write_allowance "$index"
  done
}
