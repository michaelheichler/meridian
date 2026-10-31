#!/bin/bash

# Unset because CDPATH and TMUX from the dev shell change script output.
setup_suite() {
  unset CDPATH TMUX TMUX_PANE
}
