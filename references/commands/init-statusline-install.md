If the user approves, set `statusLine` to this object.

```json
{"type": "command", "command": "bash -c 'for _d in \"${CLAUDE_CONFIG_DIR:-}\" \"$HOME/.config/claude-code\" \"$HOME/.claude\"\ndo\n  [ -z \"$_d\" ] && continue\n  f=$(ls -1 \"$_d\"/plugins/cache/meridian-marketplace/meridian/*/scripts/meridian-statusline.sh 2>/dev/null | sort -V | tail -1 || true)\n  [ -f \"$f\" ] && exec bash \"$f\"\ndone'"}
```

Use object format with `type`+`command`.
A plain string fails without an error.
If the user declines, display "○ Skipped. Run /meridian:config to install it later."
