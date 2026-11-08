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
# Display experiments: answers only in the private summary.
mkdir -p /tmp/f/dvlab
printf "step=1 name=C1 exp=avi frame=levels hz=24 extra=- rc=0 logo=n picture=? q3=7 odd=n note=\nstep=3 name=H1 exp=h1 frame=dv-ref hz=24 extra=- rc=0 logo=y picture=1 q3=- odd=n note=\n" >/tmp/f/dvlab/answers.txt
summarize /tmp/f > /tmp/out.txt
summarize /tmp/f public > /tmp/pub.txt
check "name=H1 exp=h1 frame=dv-ref hz=24 extra=- rc=0 logo=y picture=1"
grep -qF "ran: 2 steps" /tmp/pub.txt || { echo "FAIL: public dvlab line"; fail=1; }
grep -qF "logo=y" /tmp/pub.txt && { echo "FAIL: answers leaked into public summary"; fail=1; }
[ $fail = 0 ] && echo "PASS"
exit $fail
'
