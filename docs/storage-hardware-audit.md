# Storage And Hardware Audit

`scripts/analyze_storage_hardware.sh` generates a local report of filesystem
pressure, reclaimable space, block-device inventory, Btrfs restripe hints, and
firmware update signals.

## Usage

```bash
./scripts/analyze_storage_hardware.sh
```

Optional flags:

```bash
./scripts/analyze_storage_hardware.sh --top-depth 1 --top-limit 10
./scripts/analyze_storage_hardware.sh --scan-all-mounts
./scripts/analyze_storage_hardware.sh --output-dir artifacts
./scripts/analyze_storage_hardware.sh --path-only
```

## Output

Each run creates `artifacts/storage-audit-<timestamp>/` and refreshes the
`artifacts/storage-latest` symlink.

Important files:

- `storage-summary.md`: human-readable overview.
- `tables/mounts.tsv`: mount pressure and filesystem metadata.
- `tables/top-paths.tsv`: largest top-level paths under selected scan targets.
- `tables/cleanup-candidates.tsv`: likely reclaimable space after manual review.
- `tables/hardware-devices.tsv`: block-device inventory with firmware revision
  and SMART health summaries.
- `tables/btrfs-layout.tsv`: Btrfs profile and restripe/balance hints.
- `tables/firmware-status.tsv`: fwupd update availability summary.
- `commands/command-status.tsv`: which collection commands succeeded or failed.

## Notes

- SMART and fwupd details are better when run with `sudo`.
- By default, expensive `du` scans stay focused on configured target paths
  rather than every mount. Use `--scan-all-mounts` for a broader sweep.
- The script only reports; it does not delete data, vacuum journals, or run a
  Btrfs balance.
- Restripe hints are conservative and mainly target multi-device Btrfs layouts.
