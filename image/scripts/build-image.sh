#!/bin/sh
# Runs inside an x86_64 Alpine container (see image/build.sh).
# /src = repository (read-only), /out = output directory.
set -eu

SRC=/src/image
OUT=/out
W=/work
ROOT=$W/rootfs
VERSION=${NUCLAB_VERSION:-unknown}

log() { printf '\n==> %s\n' "$*"; }

log "Installing build tools and kernel"
apk add -q --no-progress linux-lts linux-firmware-i915 linux-firmware-intel \
	ukify systemd-efistub kmod cpio zstd dosfstools mtools sfdisk \
	python3 binutils gzip >/dev/null

KVER=$(basename /lib/modules/*-lts)
echo "kernel $KVER"

log "Creating root filesystem"
rm -rf "$W"; mkdir -p "$ROOT/etc/apk"
cp -a /etc/apk/keys "$ROOT/etc/apk/"
cp /etc/apk/repositories "$ROOT/etc/apk/"
apk add -q --no-progress --root "$ROOT" --initdb --no-scripts \
	busybox busybox-binsh alpine-baselayout-data musl-utils \
	kmod curl ca-certificates-bundle jq \
	pciutils i2c-tools drm_info libdrm-tests libdisplay-info-tools \
	wpa_supplicant age >/dev/null
rm -rf "$ROOT/var/cache/apk"/* "$ROOT/etc/apk/keys"
# Busybox applet links (scripts were skipped).
chroot "$ROOT" /bin/busybox --install -s
# kmod should win over the busybox module applets.
for t in modprobe insmod rmmod lsmod modinfo depmod; do
	ln -sf /bin/kmod "$ROOT/sbin/$t"
done

log "Selecting kernel modules"
M=/lib/modules/$KVER
mkdir -p "$ROOT$M"
cp -a "$M/." "$ROOT$M/"
K=$ROOT$M/kernel
# Allowlist: graphics, USB, input, network and the FAT filesystem. Internal
# disk drivers (SATA/AHCI, NVMe, eMMC) are deliberately left out so the image
# cannot touch the NUC's drives.
keep() { # keep DIR... relative to kernel/
	for d in "$@"; do
		[ -e "/lib/modules/$KVER/kernel/$d" ] || continue
		mkdir -p "$K/$(dirname "$d")"
		cp -a "/lib/modules/$KVER/kernel/$d" "$K/$d"
	done
}
rm -rf "$K"; mkdir -p "$K"
keep arch crypto lib kernel virt security \
	net/wireless net/mac80211 net/rfkill net/packet net/core \
	fs/fat fs/nls \
	drivers/gpu/drm/i915 drivers/gpu/drm/display drivers/gpu/drm/ttm \
	drivers/gpu/drm/tiny drivers/gpu/drm/virtio drivers/gpu/drm/bochs \
	drivers/media/cec drivers/acpi drivers/video drivers/i2c drivers/usb \
	drivers/hid drivers/input drivers/net/ethernet/intel \
	drivers/net/ethernet/realtek drivers/net/wireless/intel drivers/net/phy \
	drivers/net/mdio drivers/platform drivers/char drivers/pci drivers/mfd \
	drivers/misc drivers/virtio drivers/firmware drivers/base drivers/dma \
	drivers/iommu drivers/thermal drivers/leds drivers/powercap drivers/hwmon
for f in /lib/modules/$KVER/kernel/drivers/gpu/drm/*.ko* \
	/lib/modules/$KVER/kernel/drivers/net/*.ko* \
	/lib/modules/$KVER/kernel/drivers/scsi/sd_mod.ko* \
	/lib/modules/$KVER/kernel/drivers/scsi/scsi_common.ko* \
	/lib/modules/$KVER/kernel/drivers/scsi/scsi_mod.ko*; do
	[ -e "$f" ] || continue
	d=${f#/lib/modules/$KVER/kernel/}; mkdir -p "$K/$(dirname "$d")"; cp -a "$f" "$K/$d"
done
rm -f "$K/drivers/gpu/drm/i915/kvmgt.ko"*  # GVT-g host support, not needed
# Check symbols for every module the survey depends on, including transitive
# dependencies: modprobe -D alone only checks that module files exist (a
# missing hwmon.ko once stopped i915 loading on a real NUC).
depmod -b "$ROOT" -e -F "/boot/System.map-$KVER" "$KVER" 2>"$W/depmod.log" || true
: >"$W/needed"
for m in i915 e1000e r8169 igc iwlmvm usb_storage uas sd_mod vfat nls_cp437 \
	nls_iso8859_1 i2c_dev xhci_pci virtio_net virtio_pci; do
	modprobe -d "$ROOT" -S "$KVER" -D "$m" >"$W/deps" ||
		{ echo "missing module or dependency: $m" >&2; exit 1; }
	sed -n 's#^insmod .*/kernel/##p' "$W/deps" | sed 's/ .*//' >>"$W/needed"
done
bad=$(sort -u "$W/needed" | while read -r k; do
	grep -F "/kernel/$k needs unknown symbol" "$W/depmod.log" || true
done)
if [ -n "$bad" ]; then
	echo "$bad" | sed 's#.*/kernel/##' >&2
	echo "required kernel modules have unresolved symbols" >&2
	exit 1
fi
echo "module check: $(sort -u "$W/needed" | wc -l) required modules resolve"

log "Adding firmware"
FW=$ROOT/lib/firmware
mkdir -p "$FW"
cp -RL /lib/firmware/i915 "$FW/"  # -L: Alpine dedups firmware with symlinks
# Intel Wi-Fi used in Kaby Lake to Tiger Lake NUCs (8260/8265, 9260/9560, AX200/201).
for f in /lib/firmware/iwlwifi-8000C-* /lib/firmware/iwlwifi-8265-* \
	/lib/firmware/iwlwifi-9000-* /lib/firmware/iwlwifi-9260-* \
	/lib/firmware/iwlwifi-cc-a0-* /lib/firmware/iwlwifi-QuZ-a0-hr-b0-*; do
	[ -e "$f" ] && cp -L "$f" "$FW/"
done
[ -e /lib/firmware/regulatory.db.zst ] && cp -L /lib/firmware/regulatory.db* "$FW/" || true

for f in iwlwifi-8265-36.ucode.zst i915/kbl_dmc_ver1_04.bin.zst; do
	[ -f "$FW/$f" ] && [ -s "$FW/$f" ] || { echo "firmware missing from image: $f" >&2; exit 1; }
done
links=$(find "$FW" -type l)
[ -z "$links" ] || { echo "firmware symlinks left in image: $links" >&2; exit 1; }

log "Installing NUC Display Lab files"
for f in "$SRC"/rootfs/init "$SRC"/rootfs/etc/init.d/rcS "$SRC"/rootfs/usr/sbin/* "$SRC"/rootfs/usr/lib/nuclab/*.sh; do
	busybox sh -n "$f" || { echo "BusyBox shell syntax error in ${f#$SRC/}" >&2; exit 1; }
done
cp -a "$SRC/rootfs/." "$ROOT/"
mkdir -p "$ROOT/dev" "$ROOT/media/nuclab" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" "$ROOT/tmp" "$ROOT/root" "$ROOT/var/log"
mknod -m 600 "$ROOT/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "$ROOT/dev/null" c 1 3 2>/dev/null || true
chmod 0755 "$ROOT/init" "$ROOT/etc/init.d/rcS" "$ROOT/usr/sbin/"* "$ROOT/usr/lib/nuclab/"*.sh
ln -sf /usr/share/zoneinfo/UTC "$ROOT/etc/localtime" 2>/dev/null || true
{
	echo "NUCLAB_VERSION=$VERSION"
	echo "NUCLAB_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "NUCLAB_ALPINE=$(cat /etc/alpine-release)"
	echo "NUCLAB_KERNEL=$KVER"
} >"$ROOT/etc/nuclab-release"
cat >"$ROOT/etc/os-release" <<EOF
NAME="NUC Display Lab"
ID=nuclab
PRETTY_NAME="NUC Display Lab survey $VERSION"
VERSION_ID=$VERSION
EOF
# Public key(s) that report archives are encrypted to before upload.
mkdir -p "$ROOT/etc/nuclab"
grep -E '^age1[0-9a-z]+$' "$SRC/report-recipients.txt" >"$ROOT/etc/nuclab/recipients.txt" ||
	{ echo "image/report-recipients.txt has no age public key" >&2; exit 1; }
# Baked-in defaults (a nuclab.conf on the USB stick overrides them).
install -m 0600 /dev/null "$ROOT/etc/nuclab.conf"
[ -f "$SRC/local.conf" ] && grep -E '^[A-Z_]+=' "$SRC/local.conf" >"$ROOT/etc/nuclab.conf" || true

log "Packing initramfs"
du -sh "$ROOT"/lib/modules "$ROOT"/lib/firmware "$ROOT"/usr "$ROOT"/lib/modules/*/kernel/drivers/* 2>/dev/null | sort -h | tail -12
(cd "$ROOT" && find . | LC_ALL=C sort | cpio -o -H newc --quiet) |
	zstd -q -19 -T0 >"$W/initramfs.zst"
ls -lh "$W/initramfs.zst"

log "Building unified kernel image"
CMDLINE="rdinit=/init console=tty1 quiet loglevel=3 fbcon=font:TER16x32 drm.debug=0x4 log_buf_len=64M"
ukify build --linux "/boot/vmlinuz-lts" --initrd "$W/initramfs.zst" \
	--cmdline "$CMDLINE" --uname "$KVER" --os-release "@$ROOT/etc/os-release" \
	--output "$W/BOOTX64.EFI" >/dev/null
# Second entry with a serial console, used by the QEMU smoke test.
ukify build --linux "/boot/vmlinuz-lts" --initrd "$W/initramfs.zst" \
	--cmdline "$CMDLINE console=ttyS0,115200 nuclab.test=1" --uname "$KVER" \
	--output "$W/serial.efi" >/dev/null
ls -lh "$W/BOOTX64.EFI"

log "Writing disk image"
FAT=$W/fat.img
IMG=$OUT/nuclab-survey.img
SIZE_MB=512
rm -f "$FAT" "$IMG"
truncate -s $((SIZE_MB - 2))M "$FAT"
mkfs.vfat -F 32 -n NUCLAB "$FAT" >/dev/null
mmd -i "$FAT" ::/EFI ::/EFI/BOOT ::/reports
mcopy -i "$FAT" "$W/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
cp "$W/serial.efi" "$OUT/nuclab-serial-test.efi"
mcopy -i "$FAT" "$SRC/stick/README.txt" ::/README.txt
mcopy -i "$FAT" "$SRC/stick/wifi.txt" ::/wifi.txt
printf 'NUC Display Lab %s\r\n' "$VERSION" >"$W/VERSION.txt"
mcopy -i "$FAT" "$W/VERSION.txt" ::/VERSION.txt
truncate -s ${SIZE_MB}M "$IMG"
sfdisk -q "$IMG" <<EOF
label: gpt
start=2048, size=$(((SIZE_MB - 2) * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="NUCLAB"
EOF
dd if="$FAT" of="$IMG" bs=1M seek=1 conv=notrunc status=none
gzip -9 -k -f "$IMG"
ls -lh "$IMG" "$IMG.gz"
sha256sum "$IMG.gz" | sed 's#/out/##' >"$IMG.gz.sha256"
