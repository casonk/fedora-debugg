# BACKLOG.md

Portfolio backlog for this repository. Pending items are candidates for execution —
manually or via crew-chief. Entries sourced from archility audit are tagged
`[archility:YYYY-MM-DD]`; manual entries use `[manual:YYYY-MM-DD]`.

The archility twice-weekly job populates this file automatically via `archility audit --write-backlog`.
To execute a backlog item with crew-chief: `crew-chief agent "Work on item: <item text>"`.
Mark items `[x]` when complete and move them to Done.

## Pending

- [ ] [manual:2026-06-17] Verify GPU slot layout: Linux sees no AMD GPU, CPU PEG root port `00:01.0-[01]` is empty, and RTX 3090 is on chipset root port `00:1b.4` at `x4/16x`; inspect whether an AMD card occupies the top CPU x16 slot, move RTX 3090 to the CPU PEG slot if full bandwidth is desired, then rerun `FEDORA_DEBUGG_GPU_PCIE_LOAD_PROBE=1 ./scripts/run_workflow.sh`.
- [ ] [manual:2026-06-19] Redesign `ci-repair-agentic.service` authentication boundary: inventory the exact GitHub operations it performs, decide whether broad SSH access is still required, and split the service away from the personal interactive GitHub key.
- [ ] [manual:2026-06-19] Evaluate fine-grained GitHub tokens for multi-repo CI automation paths such as `ci-repair-agentic`: document which `gh` and API actions can move from SSH or broad repo tokens to least-privilege fine-grained tokens, and identify the blockers where repository write access or workflow mutation still needs a different trust model.
- [ ] [manual:2026-06-19] Evaluate per-repo deploy keys for scheduled GitHub writers: record where deploy keys are a good fit for single-repo push paths like `weekly-blog-agentic`, where they break down for multi-repo automation, and where a machine user or service account is the cleaner Phase 2 or Phase 3 boundary.

## In Progress

- [ ] [manual:2026-06-19] Start CI pipeline hardening from the live `weekly-blog-agentic` cutover: use the new deploy-key boundary as the baseline pattern, then design the next step for `ci-repair-agentic.service` around either fine-grained token auth, per-repo deploy-key fan-out, or a dedicated machine identity.

## Done
