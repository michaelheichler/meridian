If SKIP_INFERENCE=false, read `.lbwc-planning/inference.json` for the confirmed project context.
Extract NAME from `name.value` and DESCRIPTION from `purpose.value`.
For remaining user-authored content that inference does not cover, ask intentional freeform questions without options.

1. "What are the key requirements?" (pre-fill from inferred features if available)
2. "What phases do you envision?" (pre-fill from GSD recent_phases if available)
