# Debian for the NETGEAR ReadyNAS RN212

Replaces the end-of-life ReadyNAS OS 6 (Debian 8, Linux 4.4) with current
Debian (trixie, armhf) on Linux 6.6 LTS, updated through `apt`.

**Status: built, not yet booted on hardware.** Expect to need a serial console
for the first boot.

### Next steps (as of 2026-10-08)
1. Grab the live device tree from the stock OS to verify the clock values in
   `kernel/dts/alpine-rn212.dts` (cpuclk 1.4 GHz is unverified):
   `ssh root@NAS 'tar chf - -C /sys/firmware/devicetree base' > survey/live-dt.tar`
2. Install with `FLASH=0`, then test boot from the USB stick (see Install).
3. Ideally have a 3.3 V USB-serial adapter on the board UART for the first boot.

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
