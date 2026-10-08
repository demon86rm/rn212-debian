#!/bin/sh
# collect-rn212-info.sh — READ-ONLY hardware/boot survey for a ReadyNAS RN212
# running stock ReadyNAS OS 6. Writes nothing to flash or disks except the
# output tarball in the current directory.
#
# Usage (on the NAS, as root over SSH):
#   sh collect-rn212-info.sh
# Then copy rn212-info-*.tar.gz back to your computer:
#   scp root@<nas-ip>:rn212-info-*.tar.gz .

set -u
OUT="rn212-info-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/mtd" "$OUT/pci"
cd "$OUT" || exit 1

run() { # run <file> <cmd...>
	f=$1; shift
	{ echo "### $*"; "$@" 2>&1; } > "$f"
}

# --- System basics ---------------------------------------------------------
run uname.txt       uname -a
run cpuinfo.txt     cat /proc/cpuinfo
run meminfo.txt     cat /proc/meminfo
run cmdline.txt     cat /proc/cmdline
run dmesg.txt       dmesg
run lsmod.txt       cat /proc/modules
run iomem.txt       cat /proc/iomem
run interrupts.txt  cat /proc/interrupts
run mtd.txt         cat /proc/mtd
run partitions.txt  cat /proc/partitions
run mdstat.txt      cat /proc/mdstat
run mounts.txt      cat /proc/mounts
run ip.txt          ip -d addr
run version.txt     cat /etc/os-release /etc/debian_version

# --- Ethernet / PHY details ------------------------------------------------
for i in /sys/class/net/eth*; do
	n=$(basename "$i")
	run "ethtool-$n.txt" ethtool "$n"
	run "ethtool-i-$n.txt" ethtool -i "$n"
	readlink -f "$i/device" > "netdev-$n-path.txt" 2>&1
done

# --- PCI devices (lspci is not installed on stock OS) ----------------------
for d in /sys/bus/pci/devices/*; do
	b=$(basename "$d")
	{
		echo "vendor=$(cat "$d/vendor") device=$(cat "$d/device") class=$(cat "$d/class")"
		echo "driver=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
		echo "irq=$(cat "$d/irq" 2>/dev/null)"
	} > "pci/$b.txt" 2>&1
done

# --- Device tree as the running kernel sees it -----------------------------
# (decompile on the PC with: tar xf proc-device-tree.tar; dtc -I fs -O dts base/)
# (/proc/device-tree is a symlink: archive the real directory it points to)
tar cf proc-device-tree.tar -C /sys/firmware/devicetree base 2>/dev/null

# --- I2C, GPIO, hwmon (fan / thermal / RTC) --------------------------------
ls -l /sys/bus/i2c/devices/ > i2c.txt 2>&1
for d in /sys/bus/i2c/devices/*; do
	echo "$(basename "$d"): $(cat "$d/name" 2>/dev/null)" >> i2c.txt
done
cat /sys/kernel/debug/gpio > gpio.txt 2>&1 || ls -l /sys/class/gpio > gpio.txt 2>&1
for h in /sys/class/hwmon/hwmon*; do
	echo "== $h ($(cat "$h/name" 2>/dev/null))"; ls "$h"
done > hwmon.txt 2>&1
ls -l /sys/class/leds > leds.txt 2>&1

# --- Raw NAND partition backups (read-only device nodes) -------------------
# These are your recovery images for U-Boot, its environment, the DTB,
# the stock kernel and initramfs. Keep them safe.
for m in /dev/mtd[0-9]*ro; do
	n=$(basename "$m" ro)
	name=$(grep "^$n:" /proc/mtd | sed 's/.*"\(.*\)"/\1/')
	dd if="$m" of="mtd/$n-$name.bin" bs=128k 2>>mtd/dd.log
done
md5sum mtd/*.bin > mtd/md5sums.txt 2>&1

# --- Disk layout -----------------------------------------------------------
for s in /dev/sd?; do
	[ -b "$s" ] || continue
	run "sgdisk-$(basename "$s").txt" sgdisk -p "$s"
done
run mdadm-detail.txt sh -c 'for m in /dev/md*; do [ -b "$m" ] && mdadm --detail "$m"; done'

cd ..
tar czf "$OUT.tar.gz" "$OUT"
echo
echo "Done: $(pwd)/$OUT.tar.gz"
echo "Copy it to your computer, e.g.: scp root@<nas-ip>:$(pwd)/$OUT.tar.gz ."
