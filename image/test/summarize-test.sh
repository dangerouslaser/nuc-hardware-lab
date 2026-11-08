#!/bin/sh
# Fixture test for the report summary, run with BusyBox (as on the image).
# The fixture is synthetic: it mimics the expected log format of an MCDP2800.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
docker run --rm -v "$repo/image:/i:ro" alpine:3.24 sh -euc '
. /i/rootfs/usr/lib/nuclab/summarize.sh
cp -r /i/test/fixtures/mcdp2800-synthetic /tmp/f
summarize /tmp/f > /tmp/out.txt
cat /tmp/out.txt
fail=0
check() { grep -qF "$1" /tmp/out.txt || { echo "FAIL: missing: $1"; fail=1; }; }
check "Result: CONFIRMED: MegaChips MCDP2800"
check "Chip:   MegaChips MC2800 (OUI 00-60-ad, HW 2.2, FW 1.66)"
check "signature: \"DP-HDMI ADAPTOR\""
check "adaptor id: a8  OUI: 00-60-ad"
check "System:        Intel Corporation NUC7i7BNH"
check "EDID advertises Dolby Vision"
check "log: Vendor: Mega Chips"
[ $fail = 0 ] && echo "PASS"
exit $fail
'
