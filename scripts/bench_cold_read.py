#!/usr/bin/env python3
"""Cold-cache read benchmark for comparing storage tuning (read-ahead, scheduler).

For each file: evict it from the page cache (posix_fadvise DONTNEED, no root
needed; confirmed with fincore), then measure
  - sequential read() throughput with 128 KiB reads (most programs),
  - sequential mmap throughput (how model loaders and many tools read),
  - optionally the cost of random mmap access: N random 4 KiB pages, timed, and
    how many bytes the device actually read for them (read amplification).
Each measure is the median of --runs repeats. The output JSON also records
the kernel and the read-ahead of every block layer under each file, so a result
explains itself when read back later (docs/tuning-log.md).

Usage:
  scripts/bench_cold_read.py --file "4tb-m2=/mnt/4tb-m2/some/large/file" \
      [--file ...] [--runs 5] [--random-pages 4000] --out result.json
"""

from __future__ import annotations

import argparse
import json
import mmap
import os
import platform
import random
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

CHUNK = 128 * 1024


def evict(path: str) -> int:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)
    out = subprocess.run(
        ["fincore", "-nbo", "RES", path], capture_output=True, text=True, check=False
    ).stdout.split()
    return int(out[0]) if out and out[0].isdigit() else -1


def _read(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def block_layers(path: str) -> list[dict]:
    """The block devices a file's reads pass through, top (filesystem) first."""
    fields = subprocess.run(
        ["findmnt", "-no", "MAJ:MIN,SOURCE,FSTYPE,UUID", "-T", path],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.split()
    source = fields[0] if fields else ""
    layers = []
    if len(fields) >= 3 and fields[2] == "btrfs":
        # btrfs mounts report an anonymous device and keep their own read-ahead.
        uuid = fields[3] if len(fields) > 3 else ""
        layers.append(
            {
                "device": "btrfs",
                "dm_name": None,
                "read_ahead_kb": int(_read(Path(f"/sys/fs/btrfs/{uuid}/bdi/read_ahead_kb")) or -1),
                "scheduler": None,
            }
        )
        with_partition = fields[1].split("[", 1)[0]
        try:
            rdev = os.stat(with_partition).st_rdev
            source = f"{os.major(rdev)}:{os.minor(rdev)}"
        except OSError:
            source = ""
    seen = set()
    queue = [Path(f"/sys/dev/block/{source}").resolve()] if source else []
    while queue:
        dev = queue.pop(0)
        if dev in seen or not dev.exists():
            continue
        seen.add(dev)
        disk = dev if (dev / "queue").exists() else dev.parent
        name = _read(dev / "dm" / "name")
        layers.append(
            {
                "device": dev.name,
                "dm_name": name or None,
                "read_ahead_kb": int(_read(disk / "queue" / "read_ahead_kb") or -1),
                # device-mapper volumes are bio-based and have no scheduler
                "scheduler": _read(disk / "queue" / "scheduler") or None,
            }
        )
        queue.extend(p.resolve() for p in (dev / "slaves").glob("*"))
    return layers


def sectors_read(device: str) -> int | None:
    for line in Path("/proc/diskstats").read_text().splitlines():
        fields = line.split()
        if fields[2] == device:
            return int(fields[5])
    return None


def seq_read(path: str, limit: int) -> float:
    evict(path)
    fd = os.open(path, os.O_RDONLY)
    start, done = time.perf_counter(), 0
    try:
        while done < limit:
            chunk = os.read(fd, CHUNK)
            if not chunk:
                break
            done += len(chunk)
    finally:
        os.close(fd)
    return done / (time.perf_counter() - start) / 1e6


def seq_mmap(path: str, limit: int) -> float:
    evict(path)
    size = min(os.path.getsize(path), limit)
    with open(path, "rb") as handle:
        view = mmap.mmap(handle.fileno(), size, access=mmap.ACCESS_READ)
        start, total = time.perf_counter(), 0
        for offset in range(0, size, 4096):
            total += view[offset]
        seconds = time.perf_counter() - start
        view.close()
    return size / seconds / 1e6


def random_mmap(path: str, pages: int, span: int, device: str | None, seed: int) -> dict:
    evict(path)
    size = min(os.path.getsize(path), span)
    with open(path, "rb") as handle:
        view = mmap.mmap(handle.fileno(), size, access=mmap.ACCESS_READ)
        chosen = random.Random(seed).sample(range(size // 4096), min(pages, size // 4096))
        before = sectors_read(device) if device else None
        start, total = time.perf_counter(), 0
        for page in chosen:
            total += view[page * 4096]
        seconds = time.perf_counter() - start
        after = sectors_read(device) if device else None
        view.close()
    result = {"ms": seconds * 1000}
    if before is not None and after is not None:
        read_mb = (after - before) * 512 / 1e6
        result["read_mb"] = read_mb
        result["amplification"] = read_mb / (len(chosen) * 4096 / 1e6)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file", action="append", required=True, help="LABEL=PATH")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--limit-mb", type=int, default=2048, help="sequential read size")
    parser.add_argument("--mmap-mb", type=int, default=1024, help="sequential mmap size")
    parser.add_argument("--random-pages", type=int, default=0, help="0 skips the random test")
    parser.add_argument("--random-span-mb", type=int, default=4096)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    results = {}
    for spec in args.file:
        label, _, path = spec.partition("=")
        layers = block_layers(path)
        # Amplification is counted on the topmost block device with its own counters.
        device = next((layer["device"] for layer in layers if layer["device"] != "btrfs"), None)
        reads, maps, randoms, resident = [], [], [], []
        for run in range(args.runs):
            reads.append(seq_read(path, args.limit_mb << 20))
            maps.append(seq_mmap(path, args.mmap_mb << 20))
            resident.append(evict(path))
            if args.random_pages:
                randoms.append(
                    random_mmap(path, args.random_pages, args.random_span_mb << 20, device, run)
                )
        entry = {
            "layers": layers,
            "read_MBps": round(statistics.median(reads)),
            "mmap_MBps": round(statistics.median(maps)),
            "runs_read_MBps": [round(x) for x in reads],
            "runs_mmap_MBps": [round(x) for x in maps],
            "max_resident_bytes_after_evict": max(resident),
        }
        if randoms:
            entry["random_pages"] = args.random_pages
            entry["random_ms"] = round(statistics.median(r["ms"] for r in randoms))
            if all("read_mb" in r for r in randoms):
                entry["random_read_from_disk_MB"] = round(
                    statistics.median(r["read_mb"] for r in randoms)
                )
                entry["random_amplification_x"] = round(
                    statistics.median(r["amplification"] for r in randoms), 1
                )
        results[label] = entry

    report = {
        "taken_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "kernel": platform.release(),
        "runs": args.runs,
        "results": results,
    }
    Path(args.out).write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps({k: {m: v[m] for m in v if not m.startswith(("runs_", "layers"))} for k, v in results.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
