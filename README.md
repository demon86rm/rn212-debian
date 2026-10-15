# Debian for the NETGEAR ReadyNAS RN212

Replaces the end-of-life ReadyNAS OS 6 (Debian 8, Linux 4.4) with current
Debian (trixie, armhf) on Linux 6.6 LTS, updated through `apt`.

**Status: boots Debian from a USB-loaded kernel, network working.** NAND not
flashed yet.

### Status (2026-10-15)
- Debian installed on DISK2 (WD-…055924, `/dev/md9`). DISK1 (WD-…2152822,
  stock OS) is out of the box, untouched. NAND untouched.
- Test boot: kernel from the USB stick (Backup button held), root on DISK2.
  Reaches `rn212 login:` on ttyS0; DHCP, SSH and apt work.
- Serial console: 2x2 header, 3.3 V, 115200 8N1. Top-left = NAS RX,
  top-right ("P") = NAS TX, bottom-left = GND, bottom-right unused (VCC).
- Fixes found with the console:
  - SoC AHCI reports `PORTS_IMPL=0`, so all ports came up DUMMY and `md9` was
    never found (the 2026-10-09 "no DHCP" failure). `kernel/patches/170-*`
    forces the port map, as the stock 4.4 kernel did.
  - `al_eth` attaches the AR8035 PHYs as `RGMII_ID`; plain `RGMII` meant
    100% RX CRC errors.
  - `al_eth` sets `ndo_eth_ioctl`, so MII ioctls (phytool, mii-tool) work.
- Measured: iperf3 ~810 Mbit/s RX, ~650 Mbit/s TX, 0 CRC/link errors.

### Next steps
1. Fan runs at 100%: add the I2C controller with the G762 fan controller,
   DS1337 RTC and PCA9548 mux to the DT (as in the live DT), then a fan curve.
2. Flash the kernel to NAND and boot without the USB stick; mirror DISK1.

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
   remove the stick, reboot.
5. Once happy: `rn212-mirror-disk` (wipes disk 1, mirrors root, creates the
   `/srv/data` RAID1).

(`install-from-stock.sh` without `FLASH=0` also writes NAND directly.)

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
