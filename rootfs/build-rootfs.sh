#!/bin/bash
# Build the Debian armhf root filesystem for the RN212 (inside the container).
#   /work  = project, /build = case-sensitive scratch volume
# Needs: out/kernel-<ver>/linux-image-*.deb and rootfs/authorized_keys.
# Output: out/rootfs-rn212-<suite>.tar.xz, out/mtd-tools/
set -euo pipefail

SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
KVER=${KVER:-6.6.158}
ROOT=/build/rootfs-$SUITE
KDIR=/work/out/kernel-$KVER
OUT=/work/out

KEYS=/work/rootfs/authorized_keys
[ -s "$KEYS" ] || { echo "!! put your SSH public key(s) in rootfs/authorized_keys first" >&2; exit 1; }
kdeb=$(ls "$KDIR"/linux-image-*-rn212_*.deb 2>/dev/null | grep -v dbg | head -n1)
[ -n "$kdeb" ] || { echo "!! no kernel package in $KDIR, run ./build.sh kernel first" >&2; exit 1; }

# --- armhf emulation (Apple Silicon has no AArch32) ------------------------
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-arm ]; then
	mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
	# F flag: interpreter is opened now, so it works inside the chroot too.
	echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F' \
		> /proc/sys/fs/binfmt_misc/register
fi

# --- debootstrap ------------------------------------------------------------
PKGS=(
	systemd-sysv systemd-resolved systemd-timesyncd udev kmod dbus
	openssh-server sudo ca-certificates locales tzdata
	mdadm e2fsprogs btrfs-progs xfsprogs dosfstools gdisk parted
	smartmontools hdparm lm-sensors i2c-tools mtd-utils u-boot-tools
	iproute2 iputils-ping netbase curl less nano vim-tiny procps psmisc
	apt-utils unattended-upgrades bash-completion file
)
rm -rf "$ROOT"
debootstrap --arch=armhf --variant=minbase --include="$(IFS=,; echo "${PKGS[*]}")" \
	"$SUITE" "$ROOT" "$MIRROR"

# --- Configuration ------------------------------------------------------------
cp -a /work/rootfs/overlay/. "$ROOT"/
chmod 0755 "$ROOT"/usr/local/sbin/* "$ROOT"/etc/kernel/postinst.d/zz-rn212-uimage

echo rn212 > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	rn212
::1		localhost ip6-localhost ip6-loopback
EOF

cat > "$ROOT/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: $SUITE-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rm -f "$ROOT/etc/apt/sources.list"

# Root array is assembled by the kernel (0.90 autodetect); let mdadm handle the rest.
cat > "$ROOT/etc/mdadm/mdadm.conf" <<EOF
HOMEHOST <system>
# Arrays are added by rn212-mirror-disk.
EOF

# Key-only SSH as root; no passwords anywhere.
install -d -m 0700 "$ROOT/root/.ssh"
install -m 0600 "$KEYS" "$ROOT/root/.ssh/authorized_keys"
cat > "$ROOT/etc/ssh/sshd_config.d/rn212.conf" <<EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF
rm -f "$ROOT"/etc/ssh/ssh_host_*        # regenerated on first boot

echo 'drivetemp' > "$ROOT/etc/modules-load.d/rn212.conf"

chroot "$ROOT" /bin/sh -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen >/dev/null
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
passwd -l root >/dev/null
systemctl enable systemd-networkd systemd-resolved systemd-timesyncd ssh \
	rn212-fan.service rn212-leds.service serial-getty@ttyS0.service >/dev/null 2>&1
# Host keys on first boot
cat > /etc/systemd/system/rn212-ssh-hostkeys.service <<EOT
[Unit]
Description=Generate SSH host keys
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
EOT
systemctl enable rn212-ssh-hostkeys.service >/dev/null 2>&1
EOF

# Kernel package (hook builds /boot/uImage; no NAND flashing in the chroot).
cp "$kdeb" "$ROOT/tmp/"
RN212_NO_FLASH=1 chroot "$ROOT" dpkg -i "/tmp/$(basename "$kdeb")"
rm -f "$ROOT/tmp/"*.deb
chroot "$ROOT" apt-get clean
rm -rf "$ROOT"/var/lib/apt/lists/* "$ROOT"/var/log/*.log
: > "$ROOT/etc/machine-id"

# --- NAND tools for the installer (stock OS has none) -----------------------
# Debian's mtd-utils + the glibc they need, run via the bundled loader:
#   mtd-tools/lib/ld-linux-armhf.so.3 --library-path mtd-tools/lib mtd-tools/nandwrite ...
rm -rf "$OUT/mtd-tools" && mkdir -p "$OUT/mtd-tools/lib"
for t in flash_erase nandwrite nanddump; do cp "$ROOT/usr/sbin/$t" "$OUT/mtd-tools/"; done
for l in ld-linux-armhf.so.3 libc.so.6; do
	cp -L "$ROOT/lib/arm-linux-gnueabihf/$l" "$OUT/mtd-tools/lib/" 2>/dev/null ||
		cp -L "$ROOT/lib/$l" "$OUT/mtd-tools/lib/"
done

# --- Pack -----------------------------------------------------------------------
tar -C "$ROOT" --numeric-owner -cf - . | xz -T0 -6 > "$OUT/rootfs-rn212-$SUITE.tar.xz"
ls -la "$OUT/rootfs-rn212-$SUITE.tar.xz" "$OUT/mtd-tools"
du -sh "$ROOT"
