#!/bin/sh
# Read-only display hardware survey.
#
# Usage: collect.sh OUTDIR
#
# Never modesets, writes bridge registers or touches internal disks. The only
# active probe is a connector re-detect (the same thing a cable replug does)
# and a 32-byte read of the standard DP dual-mode adaptor ID at I2C 0x40, which
# i915 itself performs when it initialises an LSPCON.
set -u
OUT=$1
mkdir -p "$OUT/raw" "$OUT/edid"
umask 077

CMDLOG=$OUT/commands.log
: >"$CMDLOG"

# run NAME CMD... : capture stdout+stderr into raw/NAME, record exit status.
run() {
	name=$1; shift
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "SKIP  $name: $1 not installed" >>"$CMDLOG"; return 0
	fi
	timeout 20 "$@" >"$OUT/raw/$name" 2>&1
	rc=$?
	echo "rc=$rc $name: $*" >>"$CMDLOG"
	return 0
}
copy() { # copy FILE NAME (silently skip missing/unreadable)
	if [ -r "$1" ]; then
		timeout 10 cat "$1" >"$OUT/raw/$2" 2>>"$CMDLOG" || echo "FAIL  read $1" >>"$CMDLOG"
	else
		echo "MISS  $1" >>"$CMDLOG"
	fi
}

# --- identity --------------------------------------------------------------
cat /etc/nuclab-release >"$OUT/raw/nuclab-release" 2>/dev/null
run uname uname -a
copy /proc/cmdline cmdline
copy /proc/cpuinfo cpuinfo
{
	for f in sys_vendor product_name product_version product_family \
		board_vendor board_name board_version bios_vendor bios_version \
		bios_date bios_release ec_firmware_release; do
		printf '%s=%s\n' "$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"
	done
} >"$OUT/raw/dmi"
run lspci lspci -nnk
run lsmod lsmod

# --- re-probe DP connectors so the branch descriptor is logged ------------
# drm.debug=0x4 is on the kernel command line, so the boot probe is already
# logged; this repeats it in case the TV was connected after boot.
for s in /sys/class/drm/card*-DP-*/status; do
	[ -e "$s" ] && echo detect >"$s" 2>/dev/null
done
sleep 2

# --- DRM state ---------------------------------------------------------------
{
	for c in /sys/class/drm/card*-*; do
		[ -e "$c/status" ] || continue
		n=${c##*/}
		echo "[$n]"
		echo "status=$(cat "$c/status" 2>/dev/null)"
		echo "enabled=$(cat "$c/enabled" 2>/dev/null)"
		echo "connector_id=$(cat "$c/connector_id" 2>/dev/null)"
		echo "modes=$(tr '\n' ' ' <"$c/modes" 2>/dev/null)"
		# sysfs reports size 0 for edid, so read it before testing the size.
		cat "$c/edid" >"$OUT/edid/$n.bin" 2>/dev/null
		if [ -s "$OUT/edid/$n.bin" ]; then
			echo "edid_bytes=$(wc -c <"$OUT/edid/$n.bin")"
			if command -v di-edid-decode >/dev/null; then
				timeout 10 di-edid-decode "$OUT/edid/$n.bin" >"$OUT/edid/$n.txt" 2>&1
			fi
		else
			rm -f "$OUT/edid/$n.bin"
			echo "edid_bytes=0"
		fi
		echo
	done
} >"$OUT/raw/connectors"
run modetest modetest -M i915 -c
run drm_info drm_info
for d in /sys/kernel/debug/dri/*; do
	[ -d "$d" ] || continue
	i=${d##*/}
	case $i in *[!0-9]*) continue ;; esac  # skip PCI-address aliases
	for f in name i915_display_info i915_dmc_info i915_vbt; do
		[ -e "$d/$f" ] && copy "$d/$f" "debugfs-dri$i-$f"
	done
	for c in "$d"/DP-* "$d"/HDMI-A-*; do
		[ -e "$c/i915_dpcd" ] && copy "$c/i915_dpcd" "debugfs-dri$i-${c##*/}-i915_dpcd"
	done
done
[ -d /sys/kernel/debug/dri ] || echo "MISS  debugfs not available" >>"$CMDLOG"
for p in /sys/module/i915/parameters/*; do
	[ -r "$p" ] && printf '%s=%s\n' "${p##*/}" "$(cat "$p" 2>/dev/null)"
done >"$OUT/raw/i915-parameters" 2>/dev/null

# --- DP dual-mode adaptor ID (I2C-over-AUX, address 0x40, read-only) --------
{
	for b in /sys/bus/i2c/devices/i2c-*; do
		[ -e "$b/name" ] || continue
		name=$(cat "$b/name")
		case $name in *AUX*|*DPDDC*) ;; *) continue ;; esac
		bus=${b##*/i2c-}
		echo "### i2c-$bus ($name)"
		if command -v i2cdump >/dev/null; then
			timeout 10 i2cdump -y -r 0x00-0x1f "$bus" 0x40 b 2>&1
		else
			echo "i2cdump not installed"
		fi
		echo
	done
} >"$OUT/raw/dp-dual-mode-0x40"

# --- kernel log --------------------------------------------------------------
dmesg >"$OUT/raw/dmesg" 2>&1
grep -E 'branch: OUI|sink: OUI|LSPCON|lspcon|Mega Chips|Parade|DP-HDMI|dual mode|HDMI 2\.0|i915 .*(ERROR|WARN)|\*ERROR\*' \
	"$OUT/raw/dmesg" >"$OUT/raw/dmesg-display-highlights" 2>/dev/null

# --- summary -----------------------------------------------------------------
. /usr/lib/nuclab/summarize.sh
summarize "$OUT" >"$OUT/summary.txt"
summarize "$OUT" public >"$OUT/summary-public.txt"
