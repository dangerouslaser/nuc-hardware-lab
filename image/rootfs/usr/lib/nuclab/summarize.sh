#!/bin/sh
# summarize OUTDIR [public] : print a short human-readable report to stdout.
# "public" omits the volunteer's free-text answers; that version is the only
# one that leaves the machine unencrypted (GitHub issue body).
# Also sets NUCLAB_VERDICT and NUCLAB_CHIP for the caller.

oui_vendor() {
	case $(echo "$1" | tr 'A-F' 'a-f') in
	00-60-ad|0060ad) echo "MegaChips" ;;
	00-1c-f8|001cf8) echo "Parade" ;;
	00-90-cc|0090cc) echo "Realtek" ;;
	00-22-b9|0022b9) echo "Analogix" ;;
	*) echo "unknown" ;;
	esac
}

summarize() {
	O=$1
	MODE=${2:-full}
	R=$O/raw
	dmi() { sed -n "s/^$1=//p" "$R/dmi" 2>/dev/null; }

	echo "NUC Display Lab survey"
	echo "======================"
	sed -n 's/^NUCLAB_VERSION=/Image version: /p; s/^NUCLAB_KERNEL=/Kernel:        /p' "$R/nuclab-release" 2>/dev/null
	echo "Collected:     $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC, from the NUC clock)"
	if [ -n "$(dmi product_name | tr -d ' ')" ]; then
		echo "System:        $(dmi sys_vendor) $(dmi product_name) $(dmi product_version)"
	else  # some NUC BIOSes leave the product fields blank
		echo "System:        $(dmi board_vendor) $(dmi board_name) - board name, product name is blank"
	fi
	echo "Board:         $(dmi board_vendor) $(dmi board_name) $(dmi board_version)"
	echo "BIOS:          $(dmi bios_version) ($(dmi bios_date))"
	gpu=$(grep -E 'VGA|Display' "$R/lspci" 2>/dev/null | head -1 | sed 's/^[0-9a-f:.]* //')
	echo "GPU:           ${gpu:-unknown}"
	echo

	echo "Display converter (DP branch device)"
	echo "------------------------------------"
	NUCLAB_CHIP=""
	branch=$(grep -E 'branch: OUI ' "$R/dmesg" 2>/dev/null | sed 's/^.*\] //' | sort -u)
	if [ -n "$branch" ]; then
		echo "$branch" | while IFS= read -r l; do
			oui=$(echo "$l" | sed -n 's/.*OUI \([0-9a-fA-F-]*\).*/\1/p')
			echo "  $l"
			echo "    -> vendor: $(oui_vendor "$oui")"
		done
		first=$(echo "$branch" | grep -v 'OUI 00-00-00' | head -1)
		[ -n "$first" ] || first=$(echo "$branch" | head -1)
		oui=$(echo "$first" | sed -n 's/.*OUI \([0-9a-fA-F-]*\).*/\1/p')
		dev=$(echo "$first" | sed -n 's/.*dev-ID \([^ ]*\) HW-rev.*/\1/p')
		hw=$(echo "$first" | sed -n 's/.*HW-rev \([0-9.]*\).*/\1/p')
		sw=$(echo "$first" | sed -n 's/.*SW-rev \([0-9.]*\).*/\1/p')
		NUCLAB_CHIP="$(oui_vendor "$oui") $dev (OUI $oui, HW $hw, FW $sw)"
	else
		echo "  No 'branch: OUI' line in the kernel log."
	fi
	grep -E 'LSPCON|Mega Chips|Parade Tech' "$R/dmesg" 2>/dev/null | sed 's/^.*\] /  log: /' | sort -u | head -12
	echo

	echo "DP dual-mode adaptor ID (I2C 0x40)"
	echo "----------------------------------"
	awk '
	function hex(h,   i, v) {
		v = 0; h = tolower(h)
		for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
		return v
	}
	/^### / { bus=$0; next }
	/^[01]0: / {
		row = ($1 == "00:") ? 0 : 16
		for (i = 2; i <= 17; i++) b[bus, row + i - 2] = $i
		seen[bus] = 1
	}
	END {
		n = 0
		for (k in seen) {
			n++
			id = ""
			for (i = 0; i < 16; i++) { h = b[k, i]; if (h ~ /^[0-9a-f][0-9a-f]$/ && hex(h) >= 32 && hex(h) < 127) id = id sprintf("%c", hex(h)) }
			if (b[k, 0] == "" || b[k, 0] == "XX") continue  # no adaptor answered
			printf "  %s\n    signature: \"%s\"\n", substr(k, 5), id
			printf "    adaptor id: %s  OUI: %s-%s-%s  device id bytes: %s %s %s %s %s %s  hw: %s\n", \
				b[k,16], b[k,17], b[k,18], b[k,19], b[k,20], b[k,21], b[k,22], b[k,23], b[k,24], b[k,25], b[k,26]
		}
		if (!n) print "  No readable dual-mode adaptor found (normal for native ports)."
	}' "$R/dp-dual-mode-0x40" 2>/dev/null || echo "  (decode failed; see raw/dp-dual-mode-0x40)"
	echo

	echo "Connectors"
	echo "----------"
	awk -F= '/^\[/{n=$0} /^status=/{s=$2} /^edid_bytes=/{print "  " n " " s ", EDID " $2 " bytes"}' "$R/connectors" 2>/dev/null
	for t in "$O"/edid/*.txt; do
		[ -e "$t" ] || continue
		nm=$(grep -m1 -i 'Display Product Name' "$t" | sed 's/.*: *//')
		mf=$(grep -m1 -i 'Manufacturer:' "$t" | sed 's/^ *//')
		echo "  ${t##*/}: ${nm:-no product name} ${mf:+($mf)}"
		grep -qi 'Dolby Vision' "$t" && echo "    EDID advertises Dolby Vision"
		grep -qiE 'HDR Static Metadata' "$t" && echo "    EDID has an HDR static metadata block"
	done
	echo

	if [ -d "$O/dvlab" ]; then
		echo "Display experiments (Dolby Vision through the converter)"
		echo "--------------------------------------------------------"
		if [ "$MODE" = public ]; then
			echo "  ran: $(grep -c '^step=' "$O/dvlab/answers.txt" 2>/dev/null || echo 0) steps (answers are in the encrypted report)"
		elif [ -s "$O/dvlab/answers.txt" ]; then
			sed 's/^/  /' "$O/dvlab/answers.txt"
		else
			sed -n 's/^lab: /  lab interface: /p' "$O/dvlab/env.txt" 2>/dev/null
		fi
		echo
	fi

	if [ "$MODE" != public ] && [ -s "$O/answers.txt" ]; then
		echo "Volunteer notes"
		echo "---------------"
		sed 's/^/  /' "$O/answers.txt"
		echo
	fi

	case $NUCLAB_CHIP in
	*MegaChips*MC2800*) NUCLAB_VERDICT="CONFIRMED: MegaChips MCDP2800" ;;
	MegaChips*) NUCLAB_VERDICT="MegaChips converter, device id not MC2800" ;;
	Parade*) NUCLAB_VERDICT="NOT MegaChips: Parade converter" ;;
	"") NUCLAB_VERDICT="UNKNOWN: no converter ID was logged" ;;
	*) NUCLAB_VERDICT="Other converter: $NUCLAB_CHIP" ;;
	esac
	echo "Result: $NUCLAB_VERDICT"
	[ -n "$NUCLAB_CHIP" ] && echo "Chip:   $NUCLAB_CHIP"
	echo
	echo "Errors and skipped commands: see commands.log"
}
