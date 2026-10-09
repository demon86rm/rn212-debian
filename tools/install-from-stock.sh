#!/bin/sh
# install-from-stock.sh — install Debian on a ReadyNAS RN212 from the running
# stock ReadyNAS OS 6 (as root over SSH).
#
# What it does:
#   1. takes the SECOND disk (sdb) out of the stock RAID arrays and wipes it
#      (the stock OS keeps running, degraded, from the first disk);
#   2. partitions sdb: p1 32 GiB Debian root (RAID1 /dev/md9, 0.90 metadata,
#      degraded), p2 rest (future data mirror);
#   3. unpacks the Debian root filesystem onto /dev/md9;
#   4. backs up the NAND kernel partition and writes the new kernel to it.
# After a reboot the box runs Debian from sdb. The first disk is untouched
# until you run rn212-mirror-disk on Debian.
#
# Needs, in the same directory: uImage, rootfs-rn212-*.tar.xz and mtd-tools/
# (Debian's flash_erase/nandwrite/nanddump + glibc, run via the bundled loader).
set -eu
cd "$(dirname "$0")"

DISK=${DISK:-/dev/sdb}
FLASH=${FLASH:-1}           # FLASH=0: leave NAND alone (test via USB boot first)
ROOT_SIZE=${ROOT_SIZE:-32G}
MNT=/mnt/rn212-root
MT=$(pwd)/mtd-tools
mtd() { "$MT/lib/ld-linux-armhf.so.3" --library-path "$MT/lib" "$MT/$@"; }

CURRENT_STEP="checks"
die() { echo "ERROR: $*" >&2; exit 1; }
step() { CURRENT_STEP=$*; echo; echo "==> $*"; }
on_exit() {
	rc=$?
	[ "$rc" = 0 ] && return
	echo >&2
	echo "!! install-from-stock.sh FAILED (exit $rc) during: $CURRENT_STEP" >&2
	echo "!! NAND is untouched unless that step was the NAND write." >&2
	echo "!! Do NOT reboot with both disks in; send the output above." >&2
}
trap on_exit EXIT

[ "$(id -u)" = 0 ] || die "run as root"
grep -q 'bdtype=rn202' /proc/cmdline || die "this does not look like a ReadyNAS RN212 (no bdtype=rn202)"
[ "$(uname -r)" = "${STOCK_KERNEL:-4.4.218.alpine.1}" ] || die "run this from the stock ReadyNAS OS"

ROOTFS=$(ls rootfs-rn212-*.tar.xz 2>/dev/null | head -n1)
[ -f uImage ] || die "uImage missing"
[ -n "$ROOTFS" ] || die "rootfs-rn212-*.tar.xz missing"
chmod +x "$MT"/* "$MT"/lib/* 2>/dev/null || true
for t in flash_erase nandwrite nanddump; do
	mtd $t --version >/dev/null 2>&1 || die "mtd-tools/$t does not run on this system"
done

MTD=$(awk -F: '/"uImage"/ { print $1 }' /proc/mtd)
[ "$MTD" = mtd2 ] || die "unexpected NAND layout (uImage is '$MTD', expected mtd2)"
part_size=$(( 0x$(awk '/"uImage"/ { print $2 }' /proc/mtd) ))
img_size=$(wc -c < uImage)
[ "$img_size" -le "$part_size" ] || die "uImage ($img_size) larger than mtd2 ($part_size)"

[ -b "$DISK" ] || die "$DISK not found"
# The payload must not live on the disk we are about to wipe.
df . | tail -n1 | grep -q '^/dev/md0' || echo "note: payload is on $(df . | tail -n1 | cut -d' ' -f1)"
OTHER=/dev/sda
[ "$DISK" = /dev/sda ] && OTHER=/dev/sdb
grep -q "${OTHER#/dev/}1" /proc/mdstat || die "stock root (md0) is not running from $OTHER, refusing"

cat <<EOF

ReadyNAS RN212 -> Debian installer
  Disk to WIPE      : $DISK ($(cat /sys/block/${DISK#/dev/}/device/model 2>/dev/null))
  Stock OS stays on : $OTHER (degraded, untouched)
  Root filesystem   : $ROOTFS
  Kernel            : uImage ($img_size bytes) -> NAND $MTD
  NAND backup       : $(pwd)/mtd2-stock-backup.bin

EOF
printf 'Type INSTALL to continue: '
read -r answer
[ "$answer" = INSTALL ] || die "aborted"

step "Backing up NAND kernel partition"
dd if=/dev/mtd2ro of=mtd2-stock-backup.bin bs=128k 2>/dev/null
md5sum mtd2-stock-backup.bin

step "Stopping readynasd (X-RAID would re-add $DISK to its arrays instantly)"
# --runtime: the mask disappears at the next boot.
systemctl mask --runtime readynasd.service >/dev/null 2>&1 || true
systemctl stop readynasd.service
sleep 2
systemctl is-active --quiet readynasd.service && die "readynasd is still running"
pgrep -x readynasd >/dev/null && die "a readynasd process is still running"

step "Removing $DISK from the stock RAID arrays"
swapoff -a || true
for md in $(awk '/^md/ { print $1 }' /proc/mdstat); do
	for p in $(mdadm --detail "/dev/$md" | awk -v d="$DISK" '$NF ~ "^"d { print $NF }'); do
		echo "  $md: removing $p"
		mdadm "/dev/$md" --fail "$p" --remove "$p" || true
	done
done
sleep 2
if grep -q "${DISK#/dev/}[0-9]" /proc/mdstat; then
	cat /proc/mdstat
	die "$DISK is still part of a RAID array (see above), refusing to wipe it"
fi
for p in "$DISK"[0-9]*; do
	[ -b "$p" ] && mdadm --zero-superblock "$p" 2>/dev/null || true
done

step "Partitioning $DISK"
wipefs -a "$DISK" >/dev/null 2>&1 || true
sgdisk --zap-all "$DISK" >/dev/null
sgdisk -n 1:2048:+"$ROOT_SIZE" -t 1:FD00 -c 1:rn212-root \
       -n 2:0:0               -t 2:FD00 -c 2:rn212-data "$DISK"
blockdev --rereadpt "$DISK" 2>/dev/null || { sleep 3; blockdev --rereadpt "$DISK"; }
sleep 2
sgdisk -p "$DISK"

step "Creating root array /dev/md9 (RAID1, metadata 0.90, degraded)"
mdadm --create /dev/md9 --run --metadata=0.90 --level=1 --raid-devices=2 "${DISK}1" missing
mkfs.ext4 -q -F -L rn212-root /dev/md9

step "Unpacking Debian ($ROOTFS)"
mkdir -p "$MNT"
mount /dev/md9 "$MNT"
xz -dc "$ROOTFS" | tar -x --numeric-owner -C "$MNT"
cp mtd2-stock-backup.bin "$MNT/root/"
sync
umount "$MNT"
mdadm --stop /dev/md9

if [ "$FLASH" != 1 ]; then
	cat <<EOF

Debian is on $DISK, NAND NOT touched (FLASH=0).

IMPORTANT: never boot the stock OS while this disk is inserted: its X-RAID
auto-repair would pull $DISK back into the stock arrays and overwrite Debian.

  1. poweroff                      (now; not reboot)
  2. remove the OTHER disk ($OTHER, stock OS), keep $DISK in
  3. plug in the USB stick (usb-boot/* on FAT32), power on
     -> U-Boot boots the new kernel from the stick, Debian from $DISK
  To go back to stock: power off, stock disk in, Debian disk out, no stick.
When Debian works, make it permanent from Debian itself:
    rn212-flash-kernel        (backs up + writes + verifies NAND)
then remove the stick.
EOF
	exit 0
fi

step "Writing kernel to NAND ($MTD)"
mtd flash_erase -q /dev/mtd2 0 0
mtd nandwrite -q -p /dev/mtd2 uImage
mtd nanddump -q -l "$img_size" -f /tmp/mtd2.verify /dev/mtd2
head -c "$img_size" /tmp/mtd2.verify | cmp - uImage ||
	die "NAND verify FAILED. Restore the stock kernel NOW (do not reboot):
  $MT/lib/ld-linux-armhf.so.3 --library-path $MT/lib $MT/flash_erase /dev/mtd2 0 0
  $MT/lib/ld-linux-armhf.so.3 --library-path $MT/lib $MT/nandwrite -p /dev/mtd2 mtd2-stock-backup.bin"
echo "  verified"

cat <<EOF

Done. Power off now (not reboot):   poweroff
Then remove the stock disk ($OTHER): with it inserted, a stock boot would
pull $DISK back into its arrays. The next boot (NAND kernel) starts Debian.
  - SSH:    ssh root@<nas-ip>        (key-only; hostname 'rn212', DHCP)
  - Serial: 115200 8N1 shows the boot log.
Then, on Debian, mirror onto the first disk (wipes the stock OS):
            rn212-mirror-disk
To go back to stock instead, rewrite the saved kernel from any Linux on the box
(or use NETGEAR's USB recovery):  mtd2-stock-backup.bin
EOF
