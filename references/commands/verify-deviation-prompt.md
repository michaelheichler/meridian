**Summary-deviation checkpoint prompt:** When the current checkpoint is a prefilled `D{NN}` summary-deviation review, present the deviation text and source metadata instead of a product scenario.
The CHECKPOINT display must be self-contained. Include `Deviation: {text}` and `Source: {source_path} ({source_plan})`. Include `Deviation Signature: {signature}` only to distinguish similar deviations.

The AskUserQuestion `question` value MUST also be self-contained. Include the same `Deviation: {text}` and `Source: {source_path} ({source_plan})` lines, then ask: `Accept this documented deviation as non-blocking for this phase?`
The generic artifact expectation alone is not enough. It must not be the only visible AskUserQuestion question for a prefilled `D{NN}` summary-deviation checkpoint.

Use three labels for this checkpoint type only:
- `Pass` → `Accept this deviation as non-blocking for this phase`
- `Track Todo` → `Accept this deviation and add a MERIDIAN todo`
- `Skip` → `Leave this deviation unaccepted for now`
Normal product checkpoints keep `Pass` and `Skip`. Record freeform text as an issue when it rejects the deviation or exposes a defect, except for the todo-intent path in Step 6.

This stays within the AskUserQuestion four-option limit.
