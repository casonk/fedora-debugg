# Tuning log

Why this workstation's performance and power settings are where they are. Each
entry records the change, where it is configured, the evidence (raw results
under `docs/benchmarks/`), the reasoning, and when to look again. Add an entry
for every tuning change, including ones that were tried and rejected, so a later
reader (or a rebuild after a CMOS reset) does not have to rediscover them.

Hardware at the time of these entries: ASUS PRIME Z390-P (BIOS 3006,
2021-10-12), Intel i9-9900K, 64 GB DDR4 (G.Skill F4-3600C18 kit running at
2666 MT/s), RTX 3090, WD SN750 2 TB NVMe (`/`, `/home`, btrfs), Phison E18 4 TB
NVMe (`/mnt/4tb-m2`, LUKS + ext4), Samsung 870 EVO 4 TB SATA SSD
(`/mnt/4tb-sata`, LUKS), Seagate 16 TB HDD (`/mnt/16tb-sata`, LUKS).

## 2026-10-18 — Disk read-ahead by drive type, and on LUKS volumes

**Change.** NVMe and SATA SSDs: read-ahead 128 KiB → 512 KiB. LUKS volumes now
get their own value by the device underneath: NVMe 2 MiB, SATA SSD 512 KiB,
HDD 8 MiB. Hard drives keep 8 MiB.

**Where.** `config/io-tuning/61-fedora-debugg-io-tuning.rules`, installed by
`sudo ./scripts/install_io_tuning.sh`; visible in tachometer's `/thermal` Rev
limiters (disk rows list each volume's read-ahead).

**Evidence.** Cold reads (file evicted with `posix_fadvise`, `fincore` = 0),
2 GiB sequential, 1 GiB mmap, medians; raw JSON in
`docs/benchmarks/2026-10-18-read-ahead/`.

| Volume | Read-ahead | read() MB/s | mmap MB/s |
|---|---|---|---|
| 4tb-m2 (LUKS on NVMe) | 128 KiB | 485 | 517 |
| | 512 KiB | 777–822 | 794–856 |
| | 1 MiB | 1158 | 1179 |
| | **2 MiB (chosen)** | **1278–1404** | **1333–1496** |
| | 4 MiB | 1372 | 1458 |
| | 8 MiB | 1608 | 1660 |
| 4tb-sata (LUKS on SATA SSD) | 128 KiB | 361 | 366 |
| | **512 KiB (chosen)** | **545** | **549** |
| home (btrfs on NVMe, untouched control) | 4 MiB (btrfs default) | 1308–1333 | 1306–1307 |

Cost of larger values for random mmap access (4000 random 4 KiB pages on
4tb-m2, median of 5; files 05-*.json):

| Read-ahead | Time | Read from disk | Amplification |
|---|---|---|---|
| 512 KiB | 804 ms | 69 MB | 4× |
| 2 MiB | 996 ms | 231 MB | 14× |
| 4 MiB | 1218 ms | 454 MB | 28× |
| 8 MiB | 1467 ms | 1006 MB | 61× |

**Reasoning.** Encryption adds latency per request that read-ahead hides, so
the LUKS volume on NVMe gained ~2.9× and passed the unencrypted btrfs control.
2 MiB balances the sequential gain against random mmap access (git packfiles on
`/mnt/4tb-m2`): 8 MiB would add ~25 % sequential but make random access 47 %
slower and read 4.4× more. The SATA SSD reaches its link limit (~545 MB/s) at
512 KiB, so more cannot help. The same 2 MiB setting measured 1404 and 1278
MB/s in two sessions: short runs carry ~10 % spread.

**Rejected.** 512 KiB on btrfs (would lower its 4 MiB default; `/home` holds
the Ollama models). 4/8 MiB on 4tb-m2 (random-access cost above).

**Revisit when.** The NVMe links change from PCIe x2 to x4 (ceiling ~1.75 →
~3.4 GB/s), the workload on `/mnt/4tb-m2` changes, or a longer benchmark run
(tachometer backlog) gives tighter numbers.

## 2026-10-18 — Disk I/O scheduler by drive type

**Change.** Samsung 870 EVO (SATA SSD): `bfq` → `mq-deadline`. NVMe stays
`none`, hard drives stay `bfq`. Rules match on drive type so new disks follow.

**Where.** Same udev rule as above.

**Evidence.** Not measured: every disk was under 1 % busy, so a scheduler
change cannot show up in throughput. BFQ costs CPU on a device without seek
times; on hard drives it keeps interactive reads responsive and is the only
scheduler that honours `ionice` (the AI upscaler runs at idle I/O priority).

**Revisit when.** A disk becomes busy (tachometer `/thermal` Disks chart).

## 2026-10-18 — GPU power cap 250 W (stock 420 W)

**Change.** RTX 3090 power limit 420 W → 250 W, persistent; `nvidia-persistenced`
enabled.

**Where.** `sudo ./scripts/install_gpu_power_limit.sh --watts 250`
(`/etc/fedora-debugg/gpu-power-limit.conf`); adjustable from tachometer's
`/thermal` page through `scripts/fedora-debugg-limiter`.

**Evidence.** Running clockwork's AI upscaler unthrottled, the GPU drew ~308 W
and reached 91 °C (once reporting its fan at 0 %), the CPU package 95 °C; the
GPU's counters show ~90 h of lifetime software thermal slowdown. With the cap
and the upscaler's own throttling the GPU drew ~150–210 W at 69–73 °C, fan ~65 %.
Tachometer's host-samples history holds the temperature, fan and power series.

**Reasoning.** The machine was loud and hot under sustained GPU work; 250 W
keeps most of the performance for inference and transcoding.

**Revisit when.** After the cooling check (backlog) or a GPU/case change.

## 2026-10-18 — AI upscaler throttling (clockwork)

**Change.** `clockwork-upscale` runs at 35 % duty, pauses at GPU ≥ 72 °C or CPU
package ≥ 78 °C (median of readings; resumes 6 °C lower), 2 CPU threads.

**Where.** `clockwork/config/upscale.env.local` (example in
`config/upscale.env.example`).

**Evidence.** Unthrottled 360p animation rendered at ~85 fps with the
temperatures above; throttled ~16–22 fps with the GPU near 70 °C. CPU package
readings spike for a moment whenever a process wakes, so a single reading
tripped the guard constantly; the median over ~3 s does not.

## 2026-10-18 — Power profile `powersave` (was `throughput-performance`)

**Change.** tuned profile switched from tachometer's `/thermal` page.

**Evidence.** Governor `powersave`, energy preference `power`, turbo off
(ceiling 3.6 GHz instead of 5.0 GHz), idle around 800 MHz; CPU package 61 →
52 °C at idle. `tuned-adm verify` differs only on SATA link power management of
two ports that do not support it. CPU limits otherwise unchanged: RAPL PL1 95 W,
PL2 210 W.

**Trade-offs.** CPU-heavy work (builds, CPU video decode) is slower without
turbo; writeback is delayed (`vm.laptop_mode`); audio/USB/SATA power saving can
cause small wake delays. `balanced` is the middle ground.

**Revisit when.** CPU-bound work feels slow, or after the cooling check.

## 2026-10-18 — Keep XMP and PCIe ASPM off (endurance over speed)

**Decision.** Leave memory at JEDEC DDR4-2666 / 1.2 V (XMP off) and leave PCIe
ASPM disabled in the BIOS, as found.

**Reasoning.** The machine is run remotely and is expected to last; a fault
that needs hands at the machine is the costliest outcome.
- XMP 3600 overclocks the i9-9900K's memory controller (rated 2666) and raises
  DRAM voltage to 1.35 V; ASUS boards also tend to raise VCCIO/VCCSA
  automatically. On non-ECC memory a marginal setting shows up as rare crashes
  or silent data corruption, the hardest failures to diagnose remotely. The
  gain (~35 % memory bandwidth) matters little because the heavy workloads
  (LLM inference, transcoding, upscaling) are GPU-bound.
- ASPM saves a few watts at idle, but on this platform it is a known source of
  link problems (Realtek RTL8111 dropping the network, NVMe latency spikes and
  PCIe AER errors). Losing the network on a remote machine outweighs the
  wattage. Neither setting affects component longevity meaningfully.

**Revisit when.** On a platform with ECC memory, or if a measured workload
turns out to be memory-bandwidth bound.

## 2026-10-18 — Network card checked: nothing to tune

**Finding.** Realtek RTL8111 (`r8169`), 1 Gb/s on PCIe x1. One RX and one TX
queue (the chip has no more), ring buffers already at the hardware maximum
(256 RX / 256 TX), checksum and segmentation offloads on, `fq_codel`. Over
five days the card lost no packets (missed, FIFO, overrun and CRC counters all
0) and the link changed state twice (boot). The ~430k "dropped" in `ip -s link`
are packets the kernel discarded because nothing was listening for them; they
track the ~425k multicast packets received. PCIe ASPM stays off (see above).

**Where to watch.** tachometer `/thermal` Rev limiters (network row) and the
weekly benchmark's NIC counters.

**Revisit when.** The card reports missed or FIFO errors, or a faster NIC is
added (2.5 GbE is a next-build "nice").

## Known ceilings (cannot be changed in software)

Limits set by the hardware or board. They explain the numbers above and are
shown live as amber rows in tachometer's Rev limiters.

| Ceiling | Effect | Changeable? |
|---|---|---|
| Z390 / i9-9900K: PCIe 3.0 only | the RTX 3090 and the Phison E18 are PCIe 4.0 devices running at 3.0 | no (platform) |
| GPU in a chipset slot at x4 (of x16) | GPU traffic shares the ~3.9 GB/s DMI link with both NVMe drives | yes: move it to the empty CPU x16 slot (backlog: PCIe lane review) |
| NVMe drives at x2 (of x4) | ~1.75 GB/s per drive; `/mnt/4tb-m2` reads 1.40 GB/s cold | maybe: M.2 lane-sharing BIOS options (backlog) |
| No ECC support (CPU and chipset) | memory errors go undetected | no (next build: ECC) |
| DDR4 at 2666 MT/s | ~26 % below the kit's rating | by choice: XMP kept off (above) |
| NIC: 1 queue, 256-entry rings, 1 Gb/s | no ring or queue tuning available | no (card) |
| No BMC or Intel AMT | BIOS only reachable at the machine | no (next build: BMC) |

## Open questions (no change made)

- **NVMe links at PCIe 3.0 x2.** Both drives are x4 devices; see the PCIe lane
  review in `BACKLOG.md`.
- **btrfs read-ahead on `/home`.** 4 MiB by default; a small random-mmap test
  read ~555× more than it touched. Sequential reads (model loads) benefit; only
  revisit if random-access work on `/home` grows.
- **Firmware defaults worth a decision:** VT-x and VT-d disabled, Resizable BAR
  disabled (256 MiB BAR). (XMP and ASPM: decided above.) Recorded by
  `scripts/capture_firmware_profile.sh`.
