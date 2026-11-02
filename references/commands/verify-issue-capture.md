Create a synthesized, remediation-ready issue description. Infer severity from keywords (never ask the user):

<issue_capture_rules>

- Use the current checkpoint `Scenario` and `Expected` text, the user's response, and any visible attachment/image content available in the current conversation turn as inputs.
- Synthesize an actionable persisted `Description` that corrects typos, removes filler/hedging, preserves user intent, identifies the violated expectation, and states the observed actual behavior.
- Keep the description concise enough for a later remediation session to use without the original chat transcript or attachment payload.
- If the user includes or references an image/attachment and the content is visible and interpretable, inspect it immediately and fold the relevant facts into durable text in `Description`.
- If an image/attachment is not visible or not interpretable, do not persist `image attached`, `(Image attached)`, `screenshot attached`, `attachment attached`, or similar placeholders as evidence. Record the limitation only if it matters to remediation.
- Never persist raw screenshots, raw attachment blobs, or base64 data in the UAT artifact.
- Do not invent facts that are not present in the checkpoint, user response, or visible attachment/image evidence.
- Preserve the human-only UAT boundary by synthesizing the issue text only from current UAT evidence. Do not debug, inspect project files, run commands, or implement fixes during UAT capture.

</issue_capture_rules>

### Examples

#### Example
Raw response: "LCID still wrong after resync (Image attached)"
The checkpoint expects LCID history to include sell-to-open puts.
It must include the 100-share assignment and active sell-to-open call.
The visible attachment shows that LCID remains missing or incorrect after resync.
The realized value appears to include non-wheel stock trades.
The expected persisted `Description` states that LCID remains missing or incorrect after resync.
The realized value includes non-wheel LCID stock trades instead of intended wheel history.

#### Example

- Raw response: `Fail (Image attached)`
- The checkpoint expects the import preview to group rejected rows under the matching account.
- The attachment was not visible.
- Persist: `Import preview does not group rejected rows under the matching account.`
- Persist: `The referenced attachment was not visible.`

| Keywords | Severity |
| --- | --- |
| crash, broken, error, doesn't work, fails, exception | critical |
| wrong, incorrect, missing, not working, bug | major |
| minor, cosmetic, nitpick, small, typo, polish | minor |
| (no keyword match) | major |

Record the synthesized description and inferred severity.

Display:
```text
Issue recorded (severity: {level}). Final next-step routing shown at UAT summary.
```
