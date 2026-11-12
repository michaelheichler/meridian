For Step 3c, search the registry in parallel.
If npx is missing or the skills CLI fails, skip the search.
Otherwise, run `npx skills find "<stack-item>"` for all detected_stack items through concurrent Bash calls.
Deduplicate results against installed skills.
If detected_stack is empty, search by project type.
Display results with the `(registry)` tag.

For Step 3d, combine curated results from 2b and registry results from 3c in one AskUserQuestion multiSelect.
Tag each result `(curated)` or `(registry)`.
Use at most four visible choices, including `Skip`.
If more than three skills qualify, show the top three plus `Skip`.
Point broader discovery to `/meridian:skills`.
Install selected skills into the current project with `npx skills add <skill> -y`.
