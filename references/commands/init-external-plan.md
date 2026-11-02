If an external plan exists, ask one bounded choice with `Import external plan`, `Start fresh initialization`, or `Cancel`.

- For `Import external plan`, display `Run /lbwc:import .planning` or the explicit source path. Stop before creating `.lbwc-planning`.
- For `Start fresh initialization`, continue to Step 1. Do not read, copy, index, or modify the external source.
- For `Cancel`, leave settings and project artifacts unchanged, then stop.

`/lbwc:import` is the only import authority.
Init never copies `.planning`, creates a GSD archive, or generates an import index.
It never infers GSD state or promotes imported artifacts.
