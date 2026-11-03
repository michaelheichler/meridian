tmux_agent_context() {
  [ "${LBWC_TMUX_AGENT:-}" = 1 ] && [ -n "${LBWC_TMUX_CONTROL_ROOT:-}" ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]
}
