- If the active target needs re-verification:
  - Treat `prepare-reverification.sh` output as `archived=kept|in-round-dir|<original-uat-basename>` plus `skipped=already_archived|ready_for_verify|cap_reached`.
  - Run `prepare-reverification.sh {phase-dir}` to archive the old UAT and reset remediation state.
  - If the script outputs `skipped=already_archived`, display: `UAT already archived. Starting fresh re-verification.`
  - If the script outputs `skipped=ready_for_verify`, display: `Round {NN} remediation complete. Starting fresh re-verification.`
  - If the script outputs `skipped=cap_reached`, parse `max_rounds={N}` from the script output and display:
    ```text
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      Reached maximum UAT remediation rounds ({N}).
      Review issues manually or adjust max_uat_remediation_rounds
      in config.json.
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ```
    STOP. Do not compile context or enter a fresh verify loop.
  - If the script fails with a non-zero exit, display its error and STOP. Do not compile context.
  - If `archived=kept`, display: `Phase UAT preserved. Starting fresh re-verification in round dir.`
  - If `archived=in-round-dir`, display: `Archived previous UAT -> {round_file}. Starting fresh re-verification.`
  - Otherwise, when `archived=` is the original phase-root UAT basename, display: `Archived previous UAT -> {round_file}. Starting fresh re-verification.`
