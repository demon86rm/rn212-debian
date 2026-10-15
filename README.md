# Debian for the NETGEAR ReadyNAS RN212

Replaces the end-of-life ReadyNAS OS 6 (Debian 8, Linux 4.4) with current
Debian (trixie, armhf) on Linux 6.6 LTS, updated through `apt`.

**Status: Debian boots standalone from NAND (no USB stick), network and fan
control working.** Both disks mirrored (root `md9`, data `md10` on
`/srv/data`).

### Status (2026-10-15)
- Debian installed on DISK2 (WD-…055924), then `rn212-mirror-disk` wiped
  DISK1 (WD-…2152822, stock OS) and mirrored it: root RAID1 `md9` (32G,
  metadata 0.90) and data RAID1 `md10` (2.7T ext4, `/srv/data`). Both disks
  are WD30EFRX with ~64k power-on hours: keep backups, plan replacements.
- Kernel flashed to NAND mtd2 (2026-10-15, via the `linux-image` .deb and its
  postinst hook); stock mtd2 saved in `/var/backups/rn212-nand/` (md5
  `bc41c7f5…`). Plain power-on boots Debian to `rn212 login:`; DHCP, SSH and
  apt work. The USB stick + Backup button stays the recovery path.
- Serial console works (see [Serial console](#serial-console)).
- Fixes found with the console:
  - SoC AHCI reports `PORTS_IMPL=0`, so all ports came up DUMMY and `md9` was
    never found (the 2026-10-09 "no DHCP" failure). `kernel/patches/170-*`
    forces the port map, as the stock 4.4 kernel did.
  - `al_eth` attaches the AR8035 PHYs as `RGMII_ID`; plain `RGMII` meant
    100% RX CRC errors.
  - `al_eth` sets `ndo_eth_ioctl`, so MII ioctls (phytool, mii-tool) work.
- Measured: iperf3 ~810 Mbit/s RX, ~650 Mbit/s TX, 0 CRC/link errors.
- Fan: `rn212-fan` drives the G762 in DC mode (the stock fan barely reacts to
  PWM mode; stalls below ~10). Separate SoC (55–80 °C) and disk (38–50 °C)
  curves, floor 25 (~1400 RPM, quiet). SoC idles ~41 °C, ~60 °C with all
  four cores loaded. The SoC sensor needed a `thermal-zones` node in the DT.

### Next steps
1. RAID monitoring: `mdadm` has no `MAILADDR` / notification target yet.

(`PLAN.md` is the original analysis; this README is current.)

## How it works

| Piece | Source |
|-------|--------|
| Bootloader | stock NETGEAR U-Boot, untouched |
| Kernel | Linux 6.6 LTS + Alpine v1 driver port from the Netgear R9000 OpenWrt work (`al_eth` Ethernet, NAND, thermal, DMA, crypto, fan) |
| Device tree | NETGEAR's RN202 tree (the RN212's U-Boot ships the same one) + fixes in `kernel/dts/alpine-rn212.dts` |
| Boot | U-Boot loads the NAND `uImage` partition (mtd2): zImage + appended DTB. Command line comes from the DTB |
| Root | ext4 on `/dev/md9`: RAID1, metadata 0.90, auto-assembled by the kernel (no initramfs) |
| Updates | `apt upgrade`; kernel packages are local `.deb`s; a postinst hook rebuilds `/boot/uImage` and flashes it to NAND (backup + verify) |

## Serial console

4-pin (2x2) header on the mainboard. 3.3 V TTL, 115200 8N1. Orient it by the
pin marked "P" (top-right):

    +-----------+-----------+
    |  NAS RX   |  NAS TX   |   <- top-right is marked "P"
    | (adapter  | (adapter  |
    |   TXD)    |   RXD)    |
    +-----------+-----------+
    |   GND     |  VCC?     |
    |           | (unused,  |
    |           | leave it  |
    |           |  open)    |
    +-----------+-----------+

- Use a **3.3 V** USB-TTL adapter (tested: CH340G). Connect GND, TX, RX only;
  NAS RX works straight from the adapter's TXD, no resistor needed.
- Wire GND: without it you only get 00/80/f8 garbage bytes.
- The pins are a tight fit for Dupont jumpers; intermittent contact shows up
  as bursts of garbage. Press-fit or test hooks help.
- U-Boot, the kernel and a getty (`rn212 login:`) all use this port, on both
  stock ReadyNAS OS and this Debian.
- macOS: `screen /dev/tty.usbserial-* 115200` (or `picocom -b 115200`).

## Build (on the Mac)

```bash
./build.sh image     # container with cross toolchain (Podman)
./build.sh kernel    # -> out/kernel-6.6.158/{uImage,*.deb,config}
./build.sh rootfs    # -> out/rootfs-rn212-trixie.tar.xz (needs rootfs/authorized_keys)
./build.sh bundle    # -> out/install/ (everything the NAS needs)
```

## Install (on the NAS)

1. Stock OS running, SSH enabled. Copy `out/install/` to the NAS:
   `scp -r out/install root@NAS:/root/rn212`
2. Install Debian on disk 2 **without touching NAND**:
   `ssh -t root@NAS 'FLASH=0 sh /root/rn212/install-from-stock.sh'`, type `INSTALL`.
   Disk 1 keeps the stock OS. Disk 2 gets Debian on `/dev/md9`.
3. **Test boot from USB**: `poweroff`, pull the stock disk, copy
   `out/install/usb-boot/*` to a FAT32 (MBR) stick in the **front** port, then
   **hold the Backup button, press power, keep Backup held ~15 s**. Only then
   does U-Boot load `uImage-recovery` from the stick. Debian comes up on DHCP,
   hostname `rn212`: `ssh -i ~/.ssh/readynas_ed25519 root@<ip>`.
   **Without the Backup button** U-Boot boots stock from NAND, and the stock
   initrd factory-installs ReadyNAS OS onto the Debian disk (seen 2026-10-09).
   Never boot stock with the Debian disk inserted.
4. When Debian works: `rn212-flash-kernel` (backs up mtd2, writes, verifies),
   remove the stick, reboot. It flashes `/boot/uImage`, i.e. the kernel the
   rootfs was built with; if the stick carries a newer kernel, install that
   kernel's `linux-image-*.deb` with `dpkg -i` instead (its hook rebuilds
   `/boot/uImage` and flashes it).
5. Once happy: `rn212-mirror-disk` (wipes disk 1, mirrors root, creates the
   `/srv/data` RAID1).

(`install-from-stock.sh` without `FLASH=0` also writes NAND directly.)

## Kernel updates

`apt upgrade` updates everything except the kernel: ours is a local package
(`linux-image-*-rn212`) that is not in the Debian archive, and
`/etc/apt/preferences.d/rn212-no-debian-kernel` keeps Debian's kernels (which
can't boot this box) from ever being installed. Kernel fixes are manual:

1. Build: bump `KVER` (and/or the package revision) and run
   `./build.sh kernel && ./build.sh bundle`.
2. Test first from USB: copy `out/install/usb-boot/*` to the stick, boot
   with Backup held, check network, disks, `rn212-fan`.
3. Install: `scp out/kernel-$KVER/linux-image-*.deb` to the NAS and
   `dpkg -i` it. The `zz-rn212-uimage` hook builds `/boot/uImage` and flashes
   NAND at once (backup + verify), so only install kernels that passed step 2.
4. `rn212-flash-kernel` refuses images that don't fit mtd2 (6 MiB; 6.6.158 is
   5.5 MB). 6.6 is an LTS series: moving to the next LTS means porting the
   patches and `kernel/files/`, not just bumping `KVER`.

## Recovery

- NAND backups of every partition: `survey/rn212-info-*/mtd/`, plus
  `mtd2-stock-backup.bin` on the install path and in Debian's `/root`.
- Until `rn212-mirror-disk` runs, disk 1 still has a bootable stock OS. Only the
  stock kernel needs to go back into mtd2 (serial console, or NETGEAR's USB
  recovery image: a FAT USB stick with `NTGR_USBBOOT_INFO.txt`, `uImage-recovery`
  and `initrd-recovery.gz`, booted by holding Backup at power-on).

## Layout

```
kernel/      patches, vendor driver sources, RN212 DTS, config fragment, build script
rootfs/      rootfs build script, overlay (fan, LEDs, NAND flash hook, mirror helper)
tools/       collect-rn212-info.sh (survey), install-from-stock.sh (installer)
survey/      data collected from this unit (incl. full NAND dump)
fw/, ref/    unpacked stock firmware, R9000 OpenWrt reference tree
analysis/    decoded DTBs and U-Boot environment
```
