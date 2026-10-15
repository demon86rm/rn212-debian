#!/bin/bash
# Build the RN212 kernel inside the rn212-build container.
#   /work  = this project (bind mount, read/write)
#   /build = case-sensitive scratch volume for the kernel tree
# Outputs go to /work/out/kernel-<version>/.
set -euo pipefail

KVER=${KVER:-6.6.158}
JOBS=${JOBS:-$(nproc)}
SRC=/build/linux-$KVER
OUT=/work/out/kernel-$KVER
K=/work/kernel

mkdir -p /build/dl "$OUT"

# --- 1. Fresh, patched source tree ---------------------------------------
tarball=/build/dl/linux-$KVER.tar.xz
if [ ! -f "$tarball" ]; then
	curl -fL -o "$tarball.part" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
	mv "$tarball.part" "$tarball"
fi

if [ "${CLEAN:-0}" = 1 ] || [ ! -f "$SRC/.rn212-patched" ]; then
	rm -rf "$SRC"
	tar -C /build -xf "$tarball"
	for p in "$K"/patches/*.patch; do
		echo ">> applying $(basename "$p")"
		patch -d "$SRC" -p1 --forward --no-backup-if-mismatch < "$p"
	done
	touch "$SRC/.rn212-patched"
fi

# Vendor/forward-ported Alpine sources (overwrite mainline mach-alpine).
# Synced on every build so incremental builds pick up edits; no patch touches
# these files, and cp -a keeps mtimes so unchanged files don't rebuild.
cp -a "$K"/files/. "$SRC"/

# Device tree (always refreshed, cheap).
DTSDIR=$SRC/arch/arm/boot/dts/amazon
cp "$K"/dts/alpine-rn212.dts "$K"/dts/alpine-rn202-vendor.dtsi "$DTSDIR"/
grep -q alpine-rn212.dtb "$DTSDIR/Makefile" ||
	echo 'dtb-$(CONFIG_ARCH_ALPINE) += alpine-rn212.dtb' >> "$DTSDIR/Makefile"

cd "$SRC"

# --- 2. Config -------------------------------------------------------------
make -s multi_v7_defconfig
# Switch off every other ARMv7 platform: smaller kernel, fewer surprises.
# (Only user-visible platform symbols matter; olddefconfig restores any
# internal ARCH_* helpers that are still selected.)
grep -oE '^CONFIG_ARCH_[A-Z0-9_]+=y' .config | sed -e 's/^CONFIG_//' -e 's/=y$//' |
	grep -vxE 'ARCH_(ALPINE|MULTIPLATFORM|MULTI_V7|MULTI_V6_V7)' |
	while read -r sym; do scripts/config --disable "$sym"; done
scripts/kconfig/merge_config.sh -m .config "$K"/config/rn212.config >/dev/null
make -s olddefconfig

# Report fragment options that did not stick (missing deps / typos).
missing=0
while IFS= read -r line; do
	case "$line" in
	CONFIG_*=*)  want=$line ;;
	"# CONFIG_"*" is not set") want=$line ;;
	*) continue ;;
	esac
	sym=${want#\# }; sym=${sym%%[= ]*}
	have=$(grep -E "^($sym=|# $sym is not set)" .config || echo "# $sym is not set")
	if [ "$have" != "$want" ]; then
		echo "!! config: wanted '$want', got '$have'"; missing=1
	fi
done < "$K"/config/rn212.config
cp .config "$OUT/config"

# --- 3. Build ----------------------------------------------------------------
make -j"$JOBS" zImage modules dtbs
KREL=$(make -s kernelrelease)
make -j"$JOBS" bindeb-pkg KDEB_PKGVERSION="$KVER-1" >/dev/null
mv ../linux-image-"$KREL"_*.deb ../linux-headers-"$KREL"_*.deb ../linux-libc-dev_*.deb "$OUT"/ 2>/dev/null || true
rm -f ../linux-*.buildinfo ../linux-*.changes ../linux-image-*-dbg_*.deb

# --- 4. U-Boot image: zImage + appended DTB, legacy uImage ------------------
DTB=arch/arm/boot/dts/amazon/alpine-rn212.dtb
cp "$DTB" "$OUT"/
cat arch/arm/boot/zImage "$DTB" > "$OUT/zImage-dtb"
mkimage -A arm -O linux -T kernel -C none -a 0x8000 -e 0x8000 \
	-n "Linux-$KREL" -d "$OUT/zImage-dtb" "$OUT/uImage" >/dev/null
echo "$KREL" > "$OUT/kernelrelease"

size=$(stat -c %s "$OUT/uImage")
echo
echo "Kernel $KREL built: $OUT"
ls -la "$OUT"
# mtd2 is 6 MiB; USB recovery path loads at 0x08000000 with initrd at
# 0x08800000, so stay under 8 MiB there too.
if [ "$size" -gt $((6 * 1024 * 1024)) ]; then
	echo "!! uImage is $size bytes: too big for the 6 MiB NAND kernel partition"
	exit 1
fi
[ "$missing" = 0 ] || echo "!! some config options did not apply (see above)"
