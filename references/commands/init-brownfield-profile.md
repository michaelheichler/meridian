For Step 2a, if BROWNFIELD=true, gather a codebase profile.

- Count source files by extension with Glob. Exclude .lbwc-planning/, node_modules/, .git/, vendor/, dist/, build/, target/, .next/, **pycache**/, .venv/, coverage/.
- Store SOURCE_FILE_COUNT and look for test files, CI/CD, Docker, and monorepo indicators.
- Add Codebase Profile to STATE.md.
