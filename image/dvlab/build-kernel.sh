#!/bin/sh
# Runs in alpine:3.24. /w = ~/nuclab-dvlab. Usage: build-kernel.sh [i915|full]
set -eu
apk add -q --no-progress build-base bc bison flex perl openssl-dev elfutils-dev \
	linux-headers ncurses-dev python3 zstd xz gzip kmod diffutils findutils bash \
	cpio tar coreutils gmp-dev mpc1-dev mpfr-dev grep openssl >/dev/null
cd /w/linux
mkdir -p /w/obj
[ -f /w/obj/.config ] || cp /w/alpine-lts.config /w/obj/.config
# Alpine signs modules with its builders key; the lab image does not enforce
# signatures, so module signing is off.
./scripts/config --file /w/obj/.config --set-str LOCALVERSION "-nuclab-dvlab" \
	--disable LOCALVERSION_AUTO --disable WERROR --disable DEBUG_INFO_BTF \
	--disable MODULE_SIG --disable MODULE_SIG_ALL --disable X86_DECODER_SELFTEST \
	--set-str MODULE_SIG_KEY certs/signing_key.pem \
	--enable DEBUG_FS --module DRM_I915
make O=/w/obj olddefconfig >/dev/null
J=$(nproc)
if [ "${1:-full}" = i915 ]; then
	make O=/w/obj -j$J -s prepare modules_prepare
	make O=/w/obj -j$J -s drivers/gpu/drm/i915/
	exit 0
fi
make O=/w/obj -j$J -s bzImage modules
rm -rf /w/out; mkdir -p /w/out/root
make O=/w/obj -s INSTALL_MOD_PATH=/w/out/root INSTALL_MOD_STRIP=1 modules_install
KREL=$(cat /w/obj/include/config/kernel.release)
cp /w/obj/arch/x86/boot/bzImage /w/out/vmlinuz
cp /w/obj/System.map /w/out/System.map
cp /w/obj/.config /w/out/config
echo "$KREL" >/w/out/kernel.release
rm -f /w/out/root/lib/modules/$KREL/build /w/out/root/lib/modules/$KREL/source
tar -C /w/out -czf /w/nuclab-dvlab-kernel.tar.gz vmlinuz System.map config kernel.release root
ls -lh /w/nuclab-dvlab-kernel.tar.gz
echo "kernel $KREL"
