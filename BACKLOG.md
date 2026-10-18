# BACKLOG.md

Portfolio backlog for this repository. Pending items are candidates for execution —
manually or via crew-chief. Entries sourced from archility audit are tagged
`[archility:YYYY-MM-DD]`; manual entries use `[manual:YYYY-MM-DD]`.

The archility twice-weekly job populates this file automatically via `archility audit --write-backlog`.
To execute a backlog item with crew-chief: `crew-chief agent "Work on item: <item text>"`.
Mark items `[x]` when complete and move them to Done.

## Pending

- [ ] [manual:2026-10-15] **Ask GitHub Support to purge pre-rewrite commits** — this
  repository's published history was rewritten (most recently on 2026-10-15,
  to remove per-commit AI attribution trailers). GitHub keeps serving the old
  commits to anyone with a hash, and through the read-only `refs/pull/*` refs
  of earlier pull requests, until Support garbage-collects them. The request
  is filed once for the whole portfolio from traction-control's backlog; mark
  this done when an old hash returns 404 here. Never push an old clone's
  history back.

- [ ] [manual:2026-10-18] **Review the PCIe lane layout as a whole** (pairs with the GPU slot item below). Both NVMe drives train at PCIe 3.0 **x2** although both are x4 devices: `nvme0` WD SN750 2 TB (`/`, `/home`) at `00:1d.0`, whose port supports x4; `nvme1` Phison E18 4 TB (PCIe 4.0, `/mnt/4tb-m2`) at `00:1b.0`, whose port only offers x2. With the RTX 3090 also on the chipset at x4, all three share the Z390 DMI 3.0 uplink (~3.9 GB/s) while the CPU's x16 PEG slot sits empty. Steps: note which physical slot each drive and the GPU occupy; read the PRIME Z390-P manual's lane-sharing table (on the Z390-A, PCIEX16_3 defaults to x2 and shares SATA_5/6; M.2_1 shares SATA_2 only in SATA mode); check the BIOS onboard-device/bandwidth settings; the firmware profile (`scripts/capture_firmware_profile.sh`) shows the 870 EVO on SATA port 1 and the 16 TB drive on port 2, so if the Z390-P shares PCIEX16_3 with SATA_5/6 like the Z390-A, switching that slot to x4 would not disable a used port. Moving the GPU to the CPU slot may free chipset lanes. Verify with `lspci -vv` LnkSta (or `/sys/bus/pci/devices/*/current_link_width`) and re-run the cold-read benchmark: `/mnt/4tb-m2` reads 1.40 GB/s at 2 MiB read-ahead, close to the x2 ceiling (~1.75 GB/s); x4 should allow ~3.4 GB/s.
- [ ] [manual:2026-10-18] **BIOS support and update.** The board runs PRIME Z390-P BIOS 3006 (2021-10-12). Check ASUS for a newer release (microcode and security fixes) and read its changelog before flashing; record the settings that matter here (PCIe/M.2 bandwidth modes, SATA port enables, fan curves, power limits) in a tracked doc so they can be restored after a CMOS reset; consider capturing `dmidecode` (root) output in the snapshot workflow so firmware version and settings drift show up in analysis.
- [ ] [manual:2026-10-18] **Remote BIOS access.** The PRIME Z390-P has no BMC (IPMI/Redfish, HPE calls theirs iLO) and the Z390 chipset does not support Intel AMT (vPro needs a Q-series chipset), so firmware settings can only be changed at the machine. Options: an IP-KVM with ATX power control (PiKVM, JetKVM, BliKVM or similar) for remote BIOS screen, keyboard, power and reset, reachable only over the WireGuard/mTLS edge; or a board with a BMC in a future build. Until then, keep the firmware profile current (it runs with every `run_workflow.sh`) so a CMOS reset can be restored from the record.
- [ ] [manual:2026-10-18] **Cooling check.** Under the unthrottled AI upscaler the GPU reached 91 °C while once reporting its fan at 0 %, the CPU package sat at 90-100 °C for hours, and the GPU's counters show ~90 h of lifetime software thermal slowdown. Inspect case airflow and fan headers (three board fans spin; names unknown), confirm the GPU fans spin up under load, and check the CPU cooler mount and paste. The GPU is now capped at 250 W and tuned is on `powersave`; tachometer's `/thermal` page charts temperatures, fans and power for before/after comparison.
- [ ] [manual:2026-06-17] Verify GPU slot layout: Linux sees no AMD GPU, CPU PEG root port `00:01.0-[01]` is empty, and RTX 3090 is on chipset root port `00:1b.4` at `x4/16x`; inspect whether an AMD card occupies the top CPU x16 slot, move RTX 3090 to the CPU PEG slot if full bandwidth is desired, then rerun `FEDORA_DEBUGG_GPU_PCIE_LOAD_PROBE=1 ./scripts/run_workflow.sh`.
- [ ] [manual:2026-06-19] Redesign `ci-repair-agentic.service` authentication boundary: inventory the exact GitHub operations it performs, decide whether broad SSH access is still required, and split the service away from the personal interactive GitHub key.
- [ ] [manual:2026-06-19] Evaluate fine-grained GitHub tokens for multi-repo CI automation paths such as `ci-repair-agentic`: document which `gh` and API actions can move from SSH or broad repo tokens to least-privilege fine-grained tokens, and identify the blockers where repository write access or workflow mutation still needs a different trust model.
- [ ] [manual:2026-06-19] Evaluate per-repo deploy keys for scheduled GitHub writers: record where deploy keys are a good fit for single-repo push paths like `weekly-blog-agentic`, where they break down for multi-repo automation, and where a machine user or service account is the cleaner Phase 2 or Phase 3 boundary.
- [ ] [manual:2026-06-21] Run the new bootstrap scripts on the host and review the first real scan outputs: `sudo ./scripts/setup_security_tooling.sh`, `sudo ./scripts/init_security_tooling.sh`, then rerun the manual wrapper scripts and inspect any remaining permission, config, or service-state gaps.

## In Progress

- [ ] [manual:2026-06-19] Start CI pipeline hardening from the live `weekly-blog-agentic` cutover: use the new deploy-key boundary as the baseline pattern, then design the next step for `ci-repair-agentic.service` around either fine-grained token auth, per-repo deploy-key fan-out, or a dedicated machine identity.

## Done

- [x] [manual:2026-06-21] Phase 1 security posture inventory: added `scripts/analyze_security_posture.sh`, a focused shell test, and README docs so `fedora-debugg` can inventory malware/rootkit/audit/integrity tooling presence and summarize detection-coverage gaps without mutating the host.
- [x] [manual:2026-06-21] Phase 2 security posture integration: folded `scripts/analyze_security_posture.sh` into `run_workflow.sh`, `analysis-summary.md`, and `export_tachometer_signals.sh`; added the tracked security tool matrix under `config/security/security-tools.tsv`; and added workflow/export regression coverage so security coverage gaps now surface in the normal Fedora triage flow.
- [x] [manual:2026-06-21] Phase 3 wrapper scaffolding: added manual host-backed wrappers for ClamAV, baseline/integrity checks, and auditd evidence capture, plus focused shell tests and README guidance. The remaining work is host provisioning and first real scan runs.
