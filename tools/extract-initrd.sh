#!/bin/bash
# extract-initrd.sh <ReadyNASOS-*-arm.zip> <output-file>
# Pull the stock initrd.gz (a U-Boot ramdisk uImage) out of the NETGEAR
# firmware zip. The .img inside is a 16 KiB text header followed by a tar;
# the file is checked against the md5 in the tar's own csums.md5.
set -euo pipefail

zip=${1:?usage: $0 <firmware.zip> <output>}
out=${2:?usage: $0 <firmware.zip> <output>}
HEADER=16384

[ -f "$zip" ] || { echo "extract-initrd: $zip not found" >&2; exit 1; }
img=$(unzip -Z1 "$zip" | grep -E '\.img$' | head -n1)
[ -n "$img" ] || { echo "extract-initrd: no .img inside $zip" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

unzip -p "$zip" "$img" > "$tmp/fw.img"
head -c 21 "$tmp/fw.img" | grep -q '^info::name=ReadyNASOS' ||
	{ echo "extract-initrd: $img is not a ReadyNAS OS image" >&2; exit 1; }
tail -c +$((HEADER + 1)) "$tmp/fw.img" | tar -xf - -C "$tmp" initrd.gz csums.md5

want=$(awk '$2 == "initrd.gz" { print $1 }' "$tmp/csums.md5")
if command -v md5sum >/dev/null; then
	have=$(md5sum < "$tmp/initrd.gz" | cut -d' ' -f1)
else
	have=$(md5 -q "$tmp/initrd.gz")
fi
[ -n "$want" ] && [ "$want" = "$have" ] ||
	{ echo "extract-initrd: md5 mismatch for initrd.gz ($have, expected $want)" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
cp "$tmp/initrd.gz" "$out"
echo "extract-initrd: $img -> $out (md5 $have)"
