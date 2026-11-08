#!/bin/sh
# upload.sh ARCHIVE REPORTDIR RESULTFILE
#
# 1. GitHub: commit ARCHIVE to reports/ in GITHUB_REPO and open an issue with
#    the summary. Needs GITHUB_REPO and GITHUB_TOKEN.
# 2. If GitHub is not configured or fails: upload ARCHIVE to a temporary file
#    host (FALLBACK_UPLOAD=litterbox|0x0|none).
# 3. ntfy: push the result and links to NTFY_SERVER/NTFY_TOPIC, if set.
#
# Writes KEY=VALUE lines to RESULTFILE. Every step logs and carries on.
set -u
ARCHIVE=$1
REPORT=$2
RESULT=$3
: >"$RESULT"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

: "${GITHUB_REPO:=}" "${GITHUB_TOKEN:=}" "${NTFY_SERVER:=https://ntfy.sh}"
: "${NTFY_TOPIC:=}" "${FALLBACK_UPLOAD:=litterbox}"
UA="nuclab-survey/1"
log() { echo "[upload] $*" >&2; }

name=${ARCHIVE##*/}
verdict=$(sed -n 's/^Result: //p' "$REPORT/summary.txt" | head -1)
system=$(sed -n 's/^System: *//p' "$REPORT/summary.txt" | head -1)

gh_api() { # gh_api METHOD PATH [JSONFILE] -> body in $T/resp, prints HTTP code
	set -- "$1" "$2" "${3:-}"
	curl -sS -m 120 -o "$T/resp" -w '%{http_code}' -A "$UA" \
		-H "Authorization: Bearer $GITHUB_TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-X "$1" ${3:+--data-binary "@$3"} "https://api.github.com$2" 2>"$T/err" ||
		echo 000
}

issue_url=""
archive_url=""

if [ -n "$GITHUB_REPO" ] && [ -n "$GITHUB_TOKEN" ]; then
	log "committing archive to $GITHUB_REPO"
	base64 "$ARCHIVE" | tr -d '\n' >"$T/b64"
	jq -n --arg m "Add survey report $name" --rawfile c "$T/b64" \
		'{message: $m, content: $c}' >"$T/put.json"
	code=$(gh_api PUT "/repos/$GITHUB_REPO/contents/reports/$name" "$T/put.json")
	if [ "$code" = 201 ] || [ "$code" = 200 ]; then
		archive_url=$(jq -r '.content.html_url // empty' "$T/resp")
	else
		log "archive commit failed: HTTP $code $(jq -r '.message // empty' "$T/resp" 2>/dev/null) $(cat "$T/err")"
	fi

	log "opening issue"
	{
		echo '```'
		cat "$REPORT/summary.txt"
		echo '```'
		echo
		if [ -n "$archive_url" ]; then
			echo "Full archive: $archive_url"
		else
			echo "Full archive: upload to the repository failed (see fallback link in a comment, if any)."
		fi
		echo
		for f in dmesg-display-highlights dp-dual-mode-0x40 connectors; do
			[ -s "$REPORT/raw/$f" ] || continue
			echo "<details><summary>$f</summary>"
			echo
			echo '```'
			head -c 15000 "$REPORT/raw/$f"
			echo '```'
			echo "</details>"
			echo
		done
		echo "<details><summary>commands.log</summary>"
		echo
		echo '```'
		head -c 6000 "$REPORT/commands.log"
		echo '```'
		echo "</details>"
	} | head -c 60000 >"$T/body.md"
	jq -n --arg t "Survey: ${system:-unknown system} - ${verdict:-no result}" \
		--rawfile b "$T/body.md" '{title: $t, body: $b}' >"$T/issue.json"
	code=$(gh_api POST "/repos/$GITHUB_REPO/issues" "$T/issue.json")
	if [ "$code" = 201 ]; then
		issue_url=$(jq -r '.html_url // empty' "$T/resp")
		issue_api=$(jq -r '.url // empty' "$T/resp")
	else
		log "issue creation failed: HTTP $code $(jq -r '.message // empty' "$T/resp" 2>/dev/null) $(cat "$T/err")"
	fi
else
	log "GitHub upload not configured"
fi

if [ -z "$archive_url" ]; then
	case $FALLBACK_UPLOAD in
	litterbox)
		log "uploading archive to litterbox.catbox.moe (kept 72 hours)"
		archive_url=$(curl -fsS -m 300 -A "$UA" -F reqtype=fileupload -F time=72h \
			-F "fileToUpload=@$ARCHIVE" \
			https://litterbox.catbox.moe/resources/internals/api.php 2>"$T/err") ||
			{ log "litterbox failed: $(cat "$T/err")"; archive_url=""; }
		;;
	0x0)
		log "uploading archive to 0x0.st"
		archive_url=$(curl -fsS -m 300 -A "$UA" -F "file=@$ARCHIVE" https://0x0.st 2>"$T/err") ||
			{ log "0x0.st failed: $(cat "$T/err")"; archive_url=""; }
		;;
	esac
	case $archive_url in https://*) ;; *) archive_url="" ;; esac
	if [ -n "$archive_url" ] && [ -n "${issue_api:-}" ]; then
		jq -n --arg b "Full archive (temporary host): $archive_url" '{body: $b}' >"$T/c.json"
		gh_api POST "${issue_api#https://api.github.com}/comments" "$T/c.json" >/dev/null
	fi
fi

ntfy_ok=""
if [ -n "$NTFY_TOPIC" ]; then
	log "sending ntfy notification"
	{
		echo "${verdict:-no result}"
		echo "${system:-unknown system}"
		sed -n 's/^Chip: *//p' "$REPORT/summary.txt"
		[ -n "$issue_url" ] && echo "Issue: $issue_url"
		[ -n "$archive_url" ] && echo "Archive: $archive_url"
	} >"$T/ntfy.txt"
	click=${issue_url:-$archive_url}
	curl -fsS -m 60 -A "$UA" -H "Title: NUC survey report" -H "Tags: computer" \
		${click:+-H "Click: $click"} --data-binary "@$T/ntfy.txt" \
		"$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>"$T/err" && ntfy_ok=yes ||
		log "ntfy failed: $(cat "$T/err")"
fi

{
	echo "ISSUE_URL=$issue_url"
	echo "ARCHIVE_URL=$archive_url"
	echo "NTFY_OK=$ntfy_ok"
} >"$RESULT"
[ -n "$issue_url" ] || [ -n "$archive_url" ] || [ -n "$ntfy_ok" ]
