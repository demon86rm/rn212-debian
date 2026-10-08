# RN212 → modern Debian (path C) — findings & plan

## Firmware analysis (ReadyNASOS-6.10.10-arm.img)

- Image = 16 KiB text header (`info::name=ReadyNASOS,...,md5sum=...`) + tar.
- Tar contains:
  - `kernel.alpine` — uImage, Linux 4.4.218.alpine.1 (gcc 8.3, Jun 2023), xz zImage, no IKCONFIG.
  - `kernel` — the Armada (Marvell) kernel for RN102/104/2120/25; not ours.
  - `initrd.gz` — uImage ramdisk (lzma cpio), uClibc + busybox; `/init` is a compiled
    ReadyNAS binary (libreadynas).
  - `root.tlz` — lzma tar of the rootfs, Debian 8.11 (jessie).
  - `u-boot-rn202/204-1.2.img` — U-Boot for RN202/RN204 (Alpine). **No RN212/214 U-Boot**
    → the RN212's U-Boot is never updated by the OS; we will not touch it either.
- The RN202/204 U-Boot images embed the vendor kernel DTB (`netgear,readynas-20x`):
  4× Cortex-A15, GIC, sp804/sp805, DW I2C (RTC ds1337, fan g762, pca9548 mux),
  6× pl061 GPIO, 4× 16550 UART, internal PCIe ECAM @0xfbc00000 (Ethernet + SATA are
  PCIe endpoints here), 3× external PCIe, al-nand, al-thermal, al-serdes.
  Decompiled copies: `fw/work/dtb_*.dts`.

### Stock boot flow (from initrd strings + DTB)

| NAND (mtd) | Name        | Size   | Content |
|-----------|-------------|--------|---------|
| mtd0 | u-boot      | 1.75 MB | bootloader (keep!) |
| mtd1 | u-boot-env  | 256 KB | env (fw_env: `/dev/mtd1 0 0x20000 0x20000`) |
| mtd2 | uImage      | 6 MB   | kernel uImage |
| mtd3 | minirootfs  | 4 MB   | initramfs uImage |
| mtd4 | ubifs       | 100 MB | copy of firmware (`/media/boot`) |
| mtd5 | dts         | 128 KB | board DTB passed by U-Boot |
| mtd6 | factory-diag| 16 MB  | diagnostics |

U-Boot loads kernel (mtd2) + initrd (mtd3) + DTB (mtd5). Initrd assembles `/dev/md0`
(RAID1 of partition 1 on every disk) as root, `/dev/md1` swap, data on md127+.

## Upstream / community status

- **Mainline** (`arch/arm/boot/dts/amazon/alpine.dtsi`, `mach-alpine`): CPUs/SMP,
  GIC, arch timer, UART, MSI-X, internal PCIe (generic ECAM). **No Ethernet, NAND,
  thermal, fan glue.**
- **egorenar/openwrt `netgear-r9000` branch** (Netgear R9000/XR700 = Alpine AL-514,
  same ARM32 Alpine v1 family): Linux **6.6** with forward-ported vendor drivers —
  `al_eth` Ethernet, `al-nand`, thermal, DMA/RAID-XOR, crypto, cpuidle, EDAC, fan, MSI
  quirks. Boots with stock Netgear U-Boot via `zImage + appended DTB + uImage`.
  Its DTS is the same vendor-style DTS as ours → RN212 DTS is mostly a copy-and-adapt.
  Clone: `ref/r9000/target/linux/alpine`.

**Verdict: path C is feasible.** Ethernet is the hardest part, and the community has
already ported it to 6.6.

## Target design

- Kernel: Linux 6.6 LTS + R9000 Alpine patch set (later forward-port to 6.12 LTS),
  built as `.deb` (`make bindeb-pkg`), so updates go through apt from a small own repo or
  a manual `dpkg -i`.
- Boot: stock U-Boot, untouched. Kernel uImage (zImage + appended RN212 DTB) → mtd2.
  Small initramfs → mtd3 (or root= direct). A `postinst` hook rewrites mtd2/mtd3 on
  every kernel upgrade (like flash-kernel does).
- Root: Debian 13 "trixie" armhf on disk (`/dev/sda1` → later mdadm RAID1),
  built with `debootstrap` on a build host.
- Extras: fan control (g762), LEDs, buttons, RTC; optional OpenMediaVault / Cockpit UI.

## Steps

1. **[you] Survey the unit** while it still runs stock OS:
   enable SSH in the web UI → `scp tools/collect-rn212-info.sh root@NAS:` →
   `sh collect-rn212-info.sh` → copy the tarball back.
   This also backs up all NAND partitions (U-Boot, env, DTB, kernel). Keep it safe.
2. **[me]** Decode the RN212 DTB, U-Boot env and PCI IDs; write `alpine-rn212.dts`.
3. **[me]** Set up the cross-build (Docker/Podman on the Mac, Debian arm64/amd64
   container with `gcc-arm-linux-gnueabihf`), apply the patch set to 6.6, build kernel + DTB.
4. **[you] Serial console** (USB-TTL 3.3 V, 115200 8N1): capture the U-Boot log + `printenv`.
5. **First boot, RAM only**: TFTP or USB-load the new kernel from U-Boot (`tftpboot`/`bootm`),
   **no flashing**. Iterate until Ethernet + SATA + fan work.
6. Build the Debian trixie rootfs, partition the disks, install.
7. Flash the kernel/initrd to mtd2/mtd3. Stock U-Boot stays → reverting = reflash
   the backed-up mtd2/mtd3 or the stock firmware via USB recovery.
8. Kernel update hook + packaging; docs.

## Hardware you'll need
- USB-TTL serial adapter, **3.3 V** (FTDI / CP2102). Not 5 V, not RS-232.
- A spare disk to experiment on (wiping is fine as agreed).
