#!/bin/sh
# QEMU smoke test: boot the image under UEFI with the serial-console kernel,
# let the survey run unattended (nuclab.test=1), then pull the report back off
# the virtual USB stick. Runs in an x86_64 Alpine container. There is no Intel
# GPU here, so this checks the pipeline, not converter detection.
#
# NOTE: this performs a real upload with the settings baked into the image.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
# Optional: NUCLAB_TEST_CONF=/path/to/nuclab.conf is copied onto the test
# stick only (e.g. to try a GitHub token without baking it into the image).
conf=${NUCLAB_TEST_CONF:-/dev/null}
variant=${NUCLAB_VARIANT:-survey}
docker run --rm --platform linux/amd64 -e V="$variant" -v "$repo/out:/out" -v "$conf:/test.conf:ro" alpine:3.24 sh -euc '
apk add -q --no-progress qemu-system-x86_64 ovmf mtools >/dev/null
cp /out/nuclab-$V.img /tmp/t.img
mcopy -o -i /tmp/t.img@@1M /out/nuclab-$V-serial-test.efi ::/EFI/BOOT/BOOTX64.EFI
[ -s /test.conf ] && mcopy -o -i /tmp/t.img@@1M /test.conf ::/nuclab.conf
cp /usr/share/ovmf/bios.bin /tmp/ovmf.bin 2>/dev/null || cp /usr/share/OVMF/OVMF.fd /tmp/ovmf.bin
timeout 900 qemu-system-x86_64 -m 2048 -smp 2 -bios /tmp/ovmf.bin \
	-display none -serial file:/out/qemu-serial.log -no-reboot \
	-device qemu-xhci -drive if=none,id=stick,file=/tmp/t.img,format=raw \
	-device usb-storage,drive=stick -nic user,model=e1000e || true
mkdir -p /out/qemu-reports
mcopy -s -o -i /tmp/t.img@@1M ::/reports /out/qemu-reports/ || true
'
log=$repo/out/qemu-serial.log
grep -q NUCLAB-TEST-DONE "$log" || { echo "SMOKE TEST: did not finish"; exit 1; }
if grep -q NUCLAB-MODULE-FAIL "$log"; then
	grep NUCLAB-MODULE "$log"; echo "SMOKE TEST: a required module failed to load"; exit 1
fi
grep -q "^Result: " "$log" || { echo "SMOKE TEST: no summary on screen"; exit 1; }
if [ "$variant" = dvlab ]; then
	# No Intel GPU in QEMU: dvlab.sh must run, find no lab interface and
	# return to the survey without changing anything.
	grep -q "display experiments are not available" "$log" ||
		{ echo "SMOKE TEST: dvlab.sh did not run"; exit 1; }
	# The live copy on the stick (kept even if the run is cut short).
	ls "$repo"/out/qemu-reports/reports/nuclab-*-dvlab/progress.txt >/dev/null 2>&1 ||
		{ echo "SMOKE TEST: no live dvlab folder on the stick"; exit 1; }
fi
grep NUCLAB-MODULE-OK "$log"
echo "SMOKE TEST: passed"
