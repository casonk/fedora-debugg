# BACKLOG.md

Portfolio backlog for this repository. Pending items are candidates for execution —
manually or via crew-chief. Entries sourced from archility audit are tagged
`[archility:YYYY-MM-DD]`; manual entries use `[manual:YYYY-MM-DD]`.

The archility twice-weekly job populates this file automatically via `archility audit --write-backlog`.
To execute a backlog item with crew-chief: `crew-chief agent "Work on item: <item text>"`.
Mark items `[x]` when complete and move them to Done.

## Pending

- [ ] [manual:2026-06-17] Verify GPU slot layout: Linux sees no AMD GPU, CPU PEG root port `00:01.0-[01]` is empty, and RTX 3090 is on chipset root port `00:1b.4` at `x4/16x`; inspect whether an AMD card occupies the top CPU x16 slot, move RTX 3090 to the CPU PEG slot if full bandwidth is desired, then rerun `FEDORA_DEBUGG_GPU_PCIE_LOAD_PROBE=1 ./scripts/run_workflow.sh`.

## In Progress

## Done
