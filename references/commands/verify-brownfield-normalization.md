- **Brownfield normalization:** If Phase state (from Context at the end of this command) contains `misnamed_plans=true`, normalize all phase directories before proceeding:
  ```bash
  NORM_SCRIPT="{plugin-root}/scripts/normalize-plan-filenames.sh"
  if [ -f "$NORM_SCRIPT" ]; then
    for pdir in .meridian/phases/*/; do
      [ -d "$pdir" ] && bash "$NORM_SCRIPT" "$pdir"
    done
  fi
  ```
  Display: "⚠ Renamed misnamed plan files to `{NN}-PLAN.md` convention."
  Then re-run the canonical state resolver to refresh detection and its matching transport file because filenames changed:
  ```bash
  bash "{plugin-root}/scripts/resolve-phase-state.sh"
  ```
  The first output line is the plugin link and the remaining lines contain refreshed phase state. Use that state for all subsequent guard checks and target resolution. Record that normalization ran so Step 2 refreshes UAT resume metadata after compiling the final target.
