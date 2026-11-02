- **Brownfield normalization:** If Phase state (from Context at the end of this command) contains `misnamed_plans=true`, normalize all phase directories before proceeding:
  ```bash
  NORM_SCRIPT="{plugin-root}/scripts/normalize-plan-filenames.sh"
  if [ -f "$NORM_SCRIPT" ]; then
    for pdir in .lbwc-planning/phases/*/; do
      [ -d "$pdir" ] && bash "$NORM_SCRIPT" "$pdir"
    done
  fi
  ```
  Display: "⚠ Renamed misnamed plan files to `{NN}-PLAN.md` convention."
  Then re-run phase-detect.sh to refresh state (filenames changed):
  ```bash
  bash "{plugin-root}/scripts/phase-detect.sh" > "/tmp/.lbwc-phase-detect-${CLAUDE_SESSION_ID:-default}.txt"
  ```
  Use the refreshed phase-detect output for all subsequent guard checks and target resolution. Record that normalization ran so Step 2 refreshes UAT resume metadata after compiling the final target.
