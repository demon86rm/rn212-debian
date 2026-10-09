#!/bin/bash
# Host wrapper: run a build step inside the rn212-build container.
#   ./build.sh image     build the container image
#   ./build.sh kernel    build kernel (.deb + uImage) into out/
#   ./build.sh rootfs    build Debian armhf rootfs tarball into out/
#   ./build.sh bundle    collect everything the NAS installer needs in out/install/
#   ./build.sh shell     interactive shell in the container
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=rn212-build
VOLUME=rn212-build-cache   # case-sensitive scratch space (kernel tree, rootfs)

run() {
	podman run --rm -i $([ -t 0 ] && echo -t) --privileged \
		-v "$PWD":/work -v "$VOLUME":/build \
		-e KVER -e JOBS -e CLEAN -e KERNEL_ONLY \
		"$IMAGE" "$@"
}

# Stock firmware zip (only needed by "bundle"): $FIRMWARE_ZIP, or the newest
# ReadyNASOS-*-arm.zip in this folder or ~/Downloads.
find_firmware_zip() {
	if [ -n "${FIRMWARE_ZIP:-}" ]; then echo "$FIRMWARE_ZIP"; return; fi
	local z
	z=$(ls -t ./ReadyNASOS-*-arm.zip ~/Downloads/ReadyNASOS-*-arm.zip 2>/dev/null | head -n1)
	[ -n "$z" ] || { echo "no ReadyNASOS-*-arm.zip found; set FIRMWARE_ZIP=/path/to/zip" >&2; exit 1; }
	echo "$z"
}

case "${1:-}" in
image)  podman build -t "$IMAGE" -f container/Containerfile container ;;
kernel) run bash /work/kernel/build-kernel.sh ;;
rootfs) run bash /work/rootfs/build-rootfs.sh ;;
bundle)
	KVER=${KVER:-6.6.158}
	rm -rf out/install && mkdir -p out/install
	cp -R out/kernel-"$KVER"/uImage out/rootfs-rn212-*.tar.xz out/mtd-tools \
		tools/install-from-stock.sh out/install/
	# USB test boot: U-Boot's odmbootusb loads these from a FAT stick before NAND.
	mkdir -p out/install/usb-boot
	cp out/kernel-"$KVER"/uImage out/install/usb-boot/uImage-recovery
	# U-Boot insists on a valid ramdisk image; our kernel ignores it.
	tools/extract-initrd.sh "$(find_firmware_zip)" out/install/usb-boot/initrd-recovery.gz
	echo 'RN212 Debian test boot' > out/install/usb-boot/NTGR_USBBOOT_INFO.txt
	(cd out/install && find . -type f ! -name md5sums.txt | sort | xargs md5 -r | sed "s/ /  /" > md5sums.txt)
	ls -la out/install ;;
shell)  run bash ;;
*)      echo "usage: $0 {image|kernel|rootfs|bundle|shell}" >&2; exit 2 ;;
esac
