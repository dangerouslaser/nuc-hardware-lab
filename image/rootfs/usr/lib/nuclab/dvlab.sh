#!/bin/sh
# NUC Display Lab: Dolby Vision on the NUC7's MegaChips MCDP2800 with the
# LSPCON in level-shifter (LS) mode, so the GPU's own HDMI packets (AVI and
# the Dolby VSIF) reach the TV. v0.2.0-dvlab showed the PCON route drops the
# Dolby VSIF (reports #8/#9); see docs/MCDP2800-DV-PLAN.md.
#
#   dvlab.sh OUTDIR
#
# Interactive, only when the volunteer picks it. The switch to LS mode is
# i915.lspcon_ls_lab=1 (then 2) + an i915 unbind/bind; if the volunteer
# cannot see the screen afterwards, it switches back by itself.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
OUT=${1:?usage: dvlab.sh OUTDIR}
SHARE=/usr/share/nuclab
PARAM=/sys/module/i915/parameters/lspcon_ls_lab
TEST=""
grep -qw 'nuclab.test=1' /proc/cmdline && TEST=1
mkdir -p "$OUT"
ANS=$OUT/answers.txt
LOG=$OUT/dvprobe.log
: >"$ANS"

hr() { echo "------------------------------------------------------------------"; }
rec() { echo "$*" >>"$ANS"; }
note() { echo "$(date -u +%T) $*" >>"$LOG"; }

# ask VAR PROMPT CHOICES : repeat until the answer is one of CHOICES.
ask() {
	if [ -n "$TEST" ]; then eval "$1=?"; return; fi
	while :; do
		printf '%s\n> ' "$2"
		IFS= read -r -t 300 a || a="?"
		a=$(echo "$a" | tr 'A-Z' 'a-z' | tr -d ' ')
		[ -z "$a" ] && a="?"
		case " $3 " in *" $a "*) eval "$1=\$a"; return ;; esac
		echo "Please type one of: $3"
	done
}

wait_enter() {
	[ -n "$TEST" ] && return
	printf '%s' "${1:-Press Enter to continue.}"
	IFS= read -r -t 600 _ || true
}

mount -t debugfs none /sys/kernel/debug 2>/dev/null

i915_pci() {
	for d in /sys/bus/pci/drivers/i915/0000:*; do
		[ -e "$d" ] && { basename "$d"; return; }
	done
}

dri_dir() { # debugfs dir of the i915 device
	for d in /sys/kernel/debug/dri/*; do
		grep -q i915 "$d/name" 2>/dev/null && { echo "$d"; return; }
	done
}

snapshot() { # snapshot TAG : connector state into the report
	{
		echo "=== $1 $(date -u +%T) lspcon_ls_lab=$(cat $PARAM 2>/dev/null)"
		for c in /sys/class/drm/card*-*; do
			[ -e "$c/status" ] && echo "${c##*/} $(cat "$c/status")"
		done
		modetest -c 2>/dev/null | grep -E '^[0-9]+\s|3840x2160|1920x1080' | head -40
		dmesg | grep -iE 'LSPCON|dual mode|DVBridge' | tail -20
	} >>"$OUT/state.txt" 2>&1
}

PCI=$(i915_pci)
fbcon_vtcon() { # the vtconsole bound to the framebuffer console
	for v in /sys/class/vtconsole/vtcon*; do
		grep -qi 'frame buffer' "$v/name" 2>/dev/null && { echo "$v"; return; }
	done
}

rebind() { # rebind MODE : set lspcon_ls_lab and re-probe i915
	note "rebind lspcon_ls_lab=$1 pci=$PCI"
	echo "$1" >"$PARAM" || return 1
	# As igt core_hotunplug: release the console before unbinding.
	VT=$(fbcon_vtcon)
	[ -n "$VT" ] && echo 0 >"$VT/bind" 2>>"$LOG"
	echo "$PCI" >/sys/bus/pci/drivers/i915/unbind 2>>"$LOG"
	sleep 2
	echo "$PCI" >/sys/bus/pci/drivers/i915/bind 2>>"$LOG"
	sleep 3
	if [ ! -e "/sys/bus/pci/drivers/i915/$PCI" ]; then
		note "bind failed, retrying"
		sleep 2
		echo "$PCI" >/sys/bus/pci/drivers/i915/bind 2>>"$LOG"
		sleep 3
	fi
	[ -e "/sys/bus/pci/drivers/i915/$PCI" ] || note "i915 NOT bound after retry"
	dmesg | tail -50 >>"$LOG"
	VT=$(fbcon_vtcon)
	[ -n "$VT" ] && echo 1 >"$VT/bind" 2>>"$LOG"
	note "rebind done: $(dmesg | grep 'LSPCON LS lab' | tail -1)"
}

hdmi_connected() { # wait up to $1 s for a connected HDMI-A connector
	n=0
	while [ $n -lt "$1" ]; do
		for s in /sys/class/drm/card*-HDMI-A-*/status; do
			grep -q '^connected' "$s" 2>/dev/null && return 0
		done
		sleep 1; n=$((n + 1))
	done
	return 1
}

# --- preflight: only the NUC7's MegaChips LSPCON ---------------------------
{
	echo "dvlab: $(date -u +%FT%TZ)"
	cat /etc/nuclab-release
	echo "cmdline: $(cat /proc/cmdline)"
	echo "pci: ${PCI:-none} param: $(cat $PARAM 2>/dev/null || echo missing)"
} >"$OUT/env.txt"
# The lab file answers only for a connected, active DP connector. Its
# "route:" line says which experiments apply: mca = the NUC7's MegaChips
# LSPCON (level-shifter round), pcon = a DP-to-HDMI protocol converter on
# gen11+ (InfoFrame SDP round, e.g. the INUC 11).
LAB="" ROUTE=none
for f in /sys/kernel/debug/dri/*/DP-*/i915_lspcon_dv_lab; do
	[ -e "$f" ] || continue
	d=$(dirname "$f")
	cat "$f" >"$OUT/lab-initial-${d##*/}.txt" 2>&1 || continue
	r=$(sed -n 's/^route: //p' "$OUT/lab-initial-${d##*/}.txt")
	case $r in mca|pcon) LAB=$d ROUTE=$r; break ;; esac
done
echo "lab: ${LAB:-none} route: $ROUTE" >>"$OUT/env.txt"
[ -n "$LAB" ] && cat "$LAB/i915_lspcon_dv_lab_dpcd" >"$OUT/dpcd-vendor.txt" 2>&1
if [ "$ROUTE" = none ] || { [ "$ROUTE" = mca ] && { [ -z "$PCI" ] || [ ! -e "$PARAM" ]; }; }; then
	echo "The display experiments are not available on this NUC (its HDMI"
	echo "output is not one of the converter types they test). Nothing was changed."
	echo "no-lab-interface" >>"$OUT/env.txt"
	wait_enter
	exit 0
fi
rec "route=$ROUTE"

echo "Unpacking test pictures..."
zstd -dqf "$SHARE/dv-ref.xrgb.zst" -o /tmp/dv-ref.xrgb
zstd -dqf "$SHARE/dv-bad.xrgb.zst" -o /tmp/dv-bad.xrgb
(cd /tmp && sha256sum dv-ref.xrgb dv-bad.xrgb) >"$OUT/frames.sha256"
snapshot initial

# --- converter (PCON) round: Dolby VSIF as DP InfoFrame SDPs ---------------
pcon_step() { # pcon_step NAME EXP FRAME HZ [--hdr]
	N=$((N + 1))
	name=$1 exp=$2 frame=$3 hz=$4 extra=${5:-}
	clear
	echo "=================================================================="
	echo "  Step $N of ~8   ($name)"
	echo "=================================================================="
	case $frame in
	levels) echo "You will see: a black band with dim grey squares, a grey band,"
		echo "and a white band with light grey squares." ;;
	*) echo "You will see: either colour test bars, or a mostly green/purple"
	   echo "noisy picture. Either is fine; we only want to know which." ;;
	esac
	echo
	echo "Note the step number ($N) for any photo."
	wait_enter "Press Enter to start step $N."
	echo "Showing the test picture (about 25 seconds)..."
	echo "=== step $N $name exp=$exp frame=$frame hz=$hz $extra" >>"$LOG"
	if [ "$frame" = levels ]; then src="--pattern levels"; else src="--frame /tmp/$frame.xrgb"; fi
	# shellcheck disable=SC2086
	timeout -s KILL 60 dvprobe --connector dp --debugfs "$LAB" --exp "$exp" \
		--hz "$hz" --secs 20 --log "$LOG" $src $extra >/dev/null 2>&1
	rc=$?
	echo off >"$LAB/i915_lspcon_dv_lab" 2>/dev/null
	cat "$LAB/i915_lspcon_dv_lab" >"$OUT/lab-after-step$N.txt" 2>&1
	clear
	echo "Step $N finished (dvprobe exit $rc)."
	hr
	if [ "$extra" = "--hdr" ]; then
		ask q1 "Did the TV show an HDR logo, or HDR picture modes? (y = yes, n = no, ? = not sure)" "y n ?"
	else
		ask q1 "Did the TV show a Dolby Vision logo, or Dolby Vision picture modes? (y/n/?)" "y n ?"
	fi
	if [ "$frame" = levels ]; then
		ask q2 "In the BLACK band, how many dim squares could you see? (0-8, ? = not sure)" "0 1 2 3 4 5 6 7 8 ?"
		ask q3 "In the WHITE band, how many light squares could you see? (0-8, ?)" "0 1 2 3 4 5 6 7 8 ?"
	else
		ask q2 "What did the picture look like? (1 = colour test bars, 2 = green/purple or noisy, 3 = black / no signal / flashing, ? = not sure)" "1 2 3 ?"
		q3=-
	fi
	ask q4 "Was anything else odd (flicker, picture dropped out, TV message)? (y/n)" "y n ?"
	notes=""
	if [ "$q4" = y ] && [ -z "$TEST" ]; then
		printf 'Briefly, what happened?\n> '
		IFS= read -r -t 300 notes || notes=""
	fi
	rec "step=$N name=$name exp=$exp frame=$frame hz=$hz extra=${extra:--} rc=$rc logo=$q1 picture=$q2 q3=$q3 odd=$q4 note=$notes"
	eval "LOGO_$name=\$q1"
}

if [ "$ROUTE" = pcon ]; then
	clear
	echo "=================================================================="
	echo "  Display experiments (about 10 minutes)"
	echo "=================================================================="
	echo
	echo "The TV will show a test picture for about 25 seconds at a time, up to"
	echo "eight times. Between pictures this screen comes back and asks what you"
	echo "saw. The TV may go black for a few seconds each time it switches; that"
	echo "is normal. Nothing is written to the NUC or the TV."
	echo
	echo "While each picture is shown, please watch the TOP-RIGHT corner of the"
	echo "TV for a \"Dolby Vision\" or \"HDR\" logo, and if you can, take a phone"
	echo "photo with the step number shown on this screen."
	hr
	wait_enter "Press Enter when the TV is on and you are ready."
	N=0
	pcon_step C1 avi levels 24
	pcon_step C2 off levels 24 --hdr
	pcon_step H1 h1 dv-ref 24
	pcon_step H1b h1b dv-ref 24
	pcon_step H2 h2 dv-ref 24
	win=""
	for h in H1 H1b H2; do
		eval "l=\$LOGO_$h"
		[ "$l" = y ] && { win=$h; break; }
	done
	wexp=$(echo "${win:-H1}" | tr 'A-Z' 'a-z')
	rec "accepted=${win:-none}"
	pcon_step NEG "$wexp" dv-bad 24
	pcon_step C1again avi levels 24
	[ -n "$win" ] && pcon_step "${win}_60" "$wexp" dv-ref 60
	snapshot pcon-after-steps
	clear
	echo "Display experiments finished. Thank you!"
	echo "The results are added to the report, which is collected next."
	hr
	sleep 2
	exit 0
fi

clear
cat <<'EOF'
==================================================================
  Display experiments, round 2 (about 10 minutes)
==================================================================

This round switches the NUC's HDMI chip into a different mode. While it
switches, the screen goes BLACK for up to a minute, maybe twice. That is
expected. Please do not press anything during a black screen.

If the screen stays black, just wait: the NUC tries a second way and
then switches back by itself, which can take up to 6 minutes. If it is
still black after 10 minutes, hold the power button to switch it off.
Nothing is changed permanently: the chip returns to normal after a full
power off (hold the power button, then switch on again).

As before, the TV then shows a test picture a few times for about 25
seconds each, and this screen asks what you saw. Watch the top-right
corner for a "Dolby Vision" logo; photos with the step number help.
EOF
hr
wait_enter "Press Enter when you are ready."

# --- switch to LS mode -------------------------------------------------------
# Each DDC variant must bring up an HDMI-A connector AND a picture the
# volunteer can read; otherwise try the next one, then switch back.
MODE=""
for m in 1 2; do
	rebind "$m"
	if ! hdmi_connected 25; then
		note "mode $m: no HDMI-A connector came up"
		snapshot "ls-mode-$m-no-connector"
		rec "ls_mode_try=$m connector=no"
		continue
	fi
	snapshot "ls-mode-$m"
	clear
	echo "=================================================================="
	echo "  The chip is now in the new mode (try $m of 2)."
	echo "=================================================================="
	echo
	if [ -n "$TEST" ]; then
		seen=1
	else
		echo "If you can read this, press Enter within 2 minutes."
		echo "(If you do nothing, the NUC tries again or switches back by itself.)"
		printf '> '
		if IFS= read -r -t 120 _; then seen=1; else seen=""; fi
	fi
	rec "ls_mode_try=$m connector=yes seen=${seen:-no}"
	if [ -n "$seen" ]; then MODE=$m; break; fi
	note "mode $m: screen not confirmed"
done
rec "ls_mode=${MODE:-none}"

N=0
# step NAME FRAME DV : one HDMI-A experiment in LS mode.
step() {
	N=$((N + 1))
	name=$1 frame=$2 dv=$3
	clear
	echo "=================================================================="
	echo "  Step $N of 3   ($name)"
	echo "=================================================================="
	case $frame in
	levels) echo "You will see: a black band with dim grey squares, a grey band,"
		echo "and a white band with light grey squares." ;;
	*) echo "You will see: either colour test bars, or a mostly green/purple"
	   echo "noisy picture. Either is fine; we only want to know which." ;;
	esac
	echo
	echo "Note the step number ($N) for any photo."
	wait_enter "Press Enter to start step $N."
	echo "Showing the test picture (about 25 seconds)..."
	echo "=== step $N $name frame=$frame dv=$dv" >>"$LOG"
	if [ "$frame" = levels ]; then src="--pattern levels"; else src="--frame /tmp/$frame.xrgb"; fi
	extra=""
	[ "$dv" = 1 ] && extra="--dv"
	DRI=$(dri_dir)
	# shellcheck disable=SC2086
	timeout -s KILL 60 dvprobe --connector hdmi --hz 24 --secs 20 --log "$LOG" \
		--info "$DRI/i915_display_info" $src $extra >/dev/null 2>&1
	rc=$?
	clear
	echo "Step $N finished (dvprobe exit $rc)."
	hr
	ask q1 "Did the TV show a Dolby Vision logo, or Dolby Vision picture modes? (y/n/?)" "y n ?"
	if [ "$frame" = levels ]; then
		ask q2 "In the BLACK band, how many dim squares could you see? (0-8, ? = not sure)" "0 1 2 3 4 5 6 7 8 ?"
		ask q3 "In the WHITE band, how many light squares could you see? (0-8, ?)" "0 1 2 3 4 5 6 7 8 ?"
	else
		ask q2 "What did the picture look like? (1 = colour test bars, 2 = green/purple or noisy, 3 = black / no signal / flashing, ? = not sure)" "1 2 3 ?"
		q3=-
	fi
	ask q4 "Was anything else odd (flicker, picture dropped out, TV message)? (y/n)" "y n ?"
	notes=""
	if [ "$q4" = y ] && [ -z "$TEST" ]; then
		printf 'Briefly, what happened?\n> '
		IFS= read -r -t 300 notes || notes=""
	fi
	rec "step=$N name=$name frame=$frame dv=$dv mode=$MODE rc=$rc logo=$q1 picture=$q2 q3=$q3 odd=$q4 note=$notes"
}

if [ -n "$MODE" ]; then
	step LS-levels levels 0
	step LS-DV dv-ref 1
	step LS-NEG dv-bad 1
	snapshot ls-after-steps
fi

# --- back to PCON mode -------------------------------------------------------
clear
echo "Switching the chip back to its normal mode (the screen goes black"
echo "for up to a minute)..."
sleep 2
rebind 0
snapshot back-to-pcon
clear
echo "=================================================================="
echo "  Display experiments finished. Thank you!"
echo "=================================================================="
if [ -n "$TEST" ]; then back=?; else
	ask back "Is this screen back to normal? (y/n)" "y n ?"
fi
rec "back_to_pcon=$back"
echo "The results are added to the report, which is collected next."
sleep 2
exit 0
