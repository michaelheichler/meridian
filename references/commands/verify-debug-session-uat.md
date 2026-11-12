**Debug-session UAT mode:**
When routed here, skip the standard phase-resolution Steps entirely. Instead:

1. Read the debug session's UAT context:
   ```bash
  UAT_CONTEXT=$(bash "{plugin-root}/scripts/compile-debug-session-context.sh" "$session_file" uat)
   ```

2. Increment the UAT round:
   ```bash
  eval "$(bash "{plugin-root}/scripts/debug-session-state.sh" increment-uat .meridian)"
   ```

3. Generate 1-3 UAT checkpoints from the session context. These must require HUMAN judgment:
   - Reproduce the original bug, is it fixed?
   - Check related workflows, any regressions visible?
   - Verify the fix from the user's perspective

4. Present checkpoints one at a time using the same CHECKPOINT + AskUserQuestion pattern from Step 5 below. Apply the same response mapping rules (Step 6) and issue handling (Step 7).

5. After all checkpoints, persist the UAT round to the session file:
   ```bash
   UAT_RESULT_JSON=$(cat <<'ENDJSON'
   {
     "mode": "uat",
     "round": {uat_round},
     "result": "{pass|issues_found}",
     "checkpoints": [
       {"id": "{checkpoint-id}", "description": "{checkpoint description}", "result": "pass|skip|issue", "user_response": "{verbatim user response}"}
     ],
     "issues": [
       {"id": "{issue-id}", "description": "{issue description}", "severity": "{critical|major|minor}"}
     ]
   }
   ENDJSON
   )
  echo "$UAT_RESULT_JSON" | bash "{plugin-root}/scripts/write-debug-session.sh" "$session_file"
   ```

6. Update session status based on results:
   - All checkpoints pass (no issues) → `bash .../debug-session-state.sh set-status .meridian complete`
   - Any issues found → `bash .../debug-session-state.sh set-status .meridian uat_failed`

7. Present debug-session UAT result:
   ```text
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Debug UAT: Round {uat_round}
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

     Session:  {session_id}
     Result:   {✓ COMPLETE | ✗ ISSUES FOUND}
     Passed:   {N}
     Issues:   {N}

   ```
   - If COMPLETE: `➜ Debug session complete. UAT verified the fix.`
   - If ISSUES: `➜ Next: /meridian:debug --resume -- Address UAT issues`

   STOP after presenting. Do not continue to the standard phase UAT steps.
