tmux_agent_context() {
  [ "${MERIDIAN_TMUX_AGENT:-}" = 1 ] && [ -n "${MERIDIAN_TMUX_CONTROL_ROOT:-}" ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]
}
