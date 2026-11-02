For Step 6b, if SCENARIO=BROWNFIELD, follow the brownfield branch.

- Run `bash "{plugin-root}/scripts/infer-project-context.sh" .lbwc-planning/codebase/ "$(pwd)"`.
- Capture the JSON output to `.lbwc-planning/inference.json` via Bash.
- Parse the JSON and display the inferred fields.

  ```text
  ◆ Inferred project context:
    Name:         {name.value} (source: {name.source})
    Tech stack:   {tech_stack.value | join(", ")} (source: {tech_stack.source})
    Architecture: {architecture.value} (source: {architecture.source})
    Purpose:      {purpose.value} (source: {purpose.source})
    Features:     {features.value | join(", ")} (source: {features.source})
  ```

- For null fields, always display `{field}: (not detected)`.

For Step 6d, confirm inference in all non-greenfield scenarios.
Use AskUserQuestion with "Does this look right?" and these choices.

- **"Yes, looks right"** → Proceed to Step 7 with inferred data as-is.
- **"Close, but needs adjustments"** → Enter correction flow (6e).
- **"Define from scratch"** → Set SKIP_INFERENCE=true and proceed to Step 7.

For Step 6e, if the user picks "Close, but needs adjustments", start the correction flow.
Display all fields as a numbered list.
Ask "Which fields would you like to correct?" as intentional freeform input without options.
Accept comma-separated field numbers, for example, 1,3,5.
Do not format the field list as a structured options array.

For each selected field, use AskUserQuestion to ask for the corrected value.
Update the inference JSON with those values.
After all corrections, display the updated summary and proceed to Step 7 with the corrected data.
Write the final confirmed or corrected data to `.lbwc-planning/inference.json` for Step 7.
