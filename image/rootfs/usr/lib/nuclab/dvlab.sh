#!/bin/sh
# NUC Display Lab: Dolby Vision signalling experiments through the NUC7's
# MegaChips MCDP2800 (docs/MCDP2800-DV-PLAN.md, section 5).
#
#   dvlab.sh OUTDIR
#
# Interactive. Each step runs dvprobe (one modeset, one experiment, then
# exit and console restore) and asks the volunteer what the TV showed.
# Order: C1, C2, H1, H1b, H2, negative control, C1 again, then 59.94 Hz for
# whichever hypothesis the TV accepted. Only run when the volunteer picks it.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
OUT=${1:?usage: dvlab.sh OUTDIR}
SHARE=/usr/share/nuclab
TEST=""
grep -qw 'nuclab.test=1' /proc/cmdline && TEST=1
mkdir -p "$OUT"
ANS=$OUT/answers.txt
LOG=$OUT/dvprobe.log
: >"$ANS"

hr() { echo "------------------------------------------------------------------"; }
rec() { echo "$*" >>"$ANS"; }

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

# --- find the lab interface ------------------------------------------------
mount -t debugfs none /sys/kernel/debug 2>/dev/null
LAB=""
for f in /sys/kernel/debug/dri/*/DP-*/i915_lspcon_dv_lab; do
	[ -e "$f" ] && { LAB=$(dirname "$f"); break; }
done
{
	echo "dvlab: $(date -u +%FT%TZ)"
	cat /etc/nuclab-release
	echo "cmdline: $(cat /proc/cmdline)"
	echo "lab: ${LAB:-none}"
} >"$OUT/env.txt"
if [ -z "$LAB" ]; then
	echo "The display experiments are not available on this NUC (no LSPCON"
	echo "DP port with the lab interface). Nothing was changed."
	echo "no-lab-interface" >>"$OUT/env.txt"
	ls -d /sys/kernel/debug/dri/*/* >>"$OUT/env.txt" 2>&1
	wait_enter
	exit 0
fi
cat "$LAB/i915_lspcon_dv_lab" >"$OUT/lab-initial.txt" 2>&1
# H3: read-only DPCD dump of the two vendor ranges, read once.
cat "$LAB/i915_lspcon_dv_lab_dpcd" >"$OUT/dpcd-vendor.txt" 2>&1
if ! grep -q 'vendor=mca' "$OUT/lab-initial.txt"; then
	echo "This NUC's converter is not the MegaChips one these tests are for."
	echo "Nothing was changed."
	wait_enter
	exit 0
fi

echo "Unpacking test pictures..."
zstd -dqf "$SHARE/dv-ref.xrgb.zst" -o /tmp/dv-ref.xrgb
zstd -dqf "$SHARE/dv-bad.xrgb.zst" -o /tmp/dv-bad.xrgb
(cd /tmp && sha256sum dv-ref.xrgb dv-bad.xrgb) >"$OUT/frames.sha256"

clear
cat <<'EOF'
==================================================================
  Display experiments (about 10 minutes)
==================================================================

The TV will show a test picture for about 25 seconds at a time, nine
times. Between pictures this screen comes back and asks what you saw.
The TV may go black for a few seconds each time it switches; that is
normal. Nothing is written to the NUC or the TV.

While each picture is shown, please:
  * watch the TOP-RIGHT corner of the TV: LG TVs briefly show a
    "Dolby Vision" or "HDR" logo when that kind of signal starts;
  * optionally press the remote's gear (settings) button, open
    Picture > Picture Mode, and note whether the modes are named
    "Dolby Vision ..." (e.g. "Dolby Vision Cinema") or "HDR ..."
    (e.g. "HDR Cinema") or neither;
  * if you can, take a phone photo of the TV with the step number
    shown below (a photo of the logo or the picture-mode list).

Close the picture-mode menu before the next step.
EOF
hr
wait_enter "Press Enter when the TV is on and you are ready."

N=0
# step NAME EXP FRAME HZ [--hdr] : run dvprobe, ask questions.
step() {
	N=$((N + 1))
	name=$1 exp=$2 frame=$3 hz=$4 extra=${5:-}
	clear
	echo "=================================================================="
	echo "  Step $N of ~9   ($name)"
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
	{
		echo "=== step $N $name exp=$exp frame=$frame hz=$hz $extra"
	} >>"$LOG"
	if [ "$frame" = levels ]; then src="--pattern levels"; else src="--frame /tmp/$frame.xrgb"; fi
	# shellcheck disable=SC2086
	timeout -s KILL 60 dvprobe --debugfs "$LAB" --exp "$exp" --hz "$hz" \
		--secs 20 --log "$LOG" $src $extra >/dev/null 2>&1
	rc=$?
	# Belt and braces: the console is back; make sure no lab packet is left.
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
	note=""
	if [ "$q4" = y ] && [ -z "$TEST" ]; then
		printf 'Briefly, what happened?\n> '
		IFS= read -r -t 300 note || note=""
	fi
	rec "step=$N name=$name exp=$exp frame=$frame hz=$hz extra=${extra:--} rc=$rc logo=$q1 picture=$q2 q3=$q3 odd=$q4 note=$note"
	eval "LOGO_$name=\$q1; PIC_$name=\$q2"
}

step C1 avi levels 24
step C2 off levels 24 --hdr
step H1 h1 dv-ref 24
step H1b h1b dv-ref 24
step H2 h2 dv-ref 24

# The negative control uses the first hypothesis the TV accepted (else h1).
win=""
for h in H1 H1b H2; do
	eval "l=\$LOGO_$h"
	[ "$l" = y ] && { win=$h; break; }
done
wexp=$(echo "${win:-H1}" | tr 'A-Z' 'a-z')
rec "accepted=${win:-none}"
step NEG "$wexp" dv-bad 24
step C1again avi levels 24
if [ -n "$win" ]; then
	step "${win}_60" "$wexp" dv-ref 60
fi

clear
echo "Display experiments finished. Thank you!"
echo "The results are added to the report, which is collected next."
hr
sleep 2
exit 0
