#!/bin/sh
# Network helpers. Source this file.

net_online() {
	# Online = default route plus a DNS answer for github.com.
	ip route 2>/dev/null | grep -q '^default' || return 1
	nslookup github.com >/dev/null 2>&1
}

net_wired_start() {
	# DHCP on every Ethernet-like interface, in the background.
	for d in /sys/class/net/*; do
		i=${d##*/}
		case $i in lo|wl*) continue ;; esac
		[ -e "$d/device" ] || continue
		ip link set "$i" up 2>/dev/null
		udhcpc -i "$i" -b -t 10 -T 3 -S -s /usr/share/udhcpc/default.script \
			-x hostname:nuclab >/dev/null 2>&1
	done
}

net_wifi_iface() {
	for d in /sys/class/net/*; do
		[ -d "$d/wireless" ] && { echo "${d##*/}"; return 0; }
	done
	return 1
}

# net_wifi_start SSID PASSWORD
net_wifi_start() {
	i=$(net_wifi_iface) || return 1
	mkdir -p /run/wpa
	umask 077
	{
		echo "ctrl_interface=/run/wpa"
		echo "network={"
		# Hex forms avoid any quoting problems with unusual names/passwords.
		printf '  ssid=%s\n' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"
		if [ -n "$2" ]; then
			wpa_passphrase "$1" "$2" | grep -E '^[[:space:]]*psk=[0-9a-f]{64}$'
		else
			echo "  key_mgmt=NONE"
		fi
		echo "  scan_ssid=1"
		echo "}"
	} >/run/wpa/wpa.conf
	pkill wpa_supplicant 2>/dev/null
	ip link set "$i" up
	wpa_supplicant -B -i "$i" -c /run/wpa/wpa.conf >/dev/null 2>&1 || return 1
	udhcpc -i "$i" -b -t 20 -T 3 -S -s /usr/share/udhcpc/default.script \
		-x hostname:nuclab >/dev/null 2>&1
}

# net_wait SECONDS
net_wait() {
	n=0
	while [ "$n" -lt "$1" ]; do
		net_online && return 0
		sleep 1; n=$((n + 1))
	done
	return 1
}

net_sync_clock() {
	# TLS needs a sane clock; the RTC is usually fine but this costs little.
	timeout 15 ntpd -n -q -p pool.ntp.org -p time.cloudflare.com >/dev/null 2>&1 || true
}
