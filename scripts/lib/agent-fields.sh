agent_field_token() {
  case "$1" in
    name|NAME) printf 'NAME' ;;
    description|DESCRIPTION|--description) printf 'DESCRIPTION' ;;
    tools|TOOLS|--tools) printf 'TOOLS' ;;
    disallowedTools|DISALLOWED_TOOLS|--disallowed-tools) printf 'DISALLOWED_TOOLS' ;;
    model|MODEL|--model) printf 'MODEL' ;;
    permissionMode|PERMISSION_MODE|--permission-mode) printf 'PERMISSION_MODE' ;;
    maxTurns|MAX_TURNS|--max-turns) printf 'MAX_TURNS' ;;
    skills|SKILLS|--skills) printf 'SKILLS' ;;
    mcpServers|MCP_SERVERS|--mcp-servers) printf 'MCP_SERVERS' ;;
    memory|MEMORY|--memory) printf 'MEMORY' ;;
    background|BACKGROUND|--background) printf 'BACKGROUND' ;;
    effort|EFFORT|--effort) printf 'EFFORT' ;;
    isolation|ISOLATION|--isolation) printf 'ISOLATION' ;;
    color|COLOR|--color) printf 'COLOR' ;;
    initialPrompt|INITIAL_PROMPT|--initial-prompt) printf 'INITIAL_PROMPT' ;;
    reasoning|REASONING|--reasoning) printf 'REASONING' ;;
    job|JOB|--job) printf 'JOB' ;;
    *) return 1 ;;
  esac
}

agent_role_is_valid() {
  jq -e --arg r "$1" '[.quality, .balanced, .budget | keys[]] | index($r) != null' \
    "$2" >/dev/null 2>&1
}
