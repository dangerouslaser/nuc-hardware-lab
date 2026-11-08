#!/bin/sh
# Download and decrypt a volunteer report.
#
#   sh image/tools/get-report.sh 12          # report linked from issue #12
#   sh image/tools/get-report.sh latest      # newest file in reports/
#   sh image/tools/get-report.sh FILE.age    # a file you already downloaded
#
# Output goes to out/reports/<name>/. Needs `gh` (logged in) and the private
# key at ~/.config/nuclab/report-key.txt (override with NUCLAB_KEY). Uses a
# local `age` if installed, otherwise Docker.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$repo/image/local.conf" 2>/dev/null || true
REPO=${GITHUB_REPO:-dangerouslaser/nuclab-reports}
KEY=${NUCLAB_KEY:-$HOME/.config/nuclab/report-key.txt}
dest=$repo/out/reports
mkdir -p "$dest"
[ -r "$KEY" ] || { echo "private key not found: $KEY" >&2; exit 1; }

arg=${1:-latest}
case $arg in
*.age)
	enc=$arg ;;
latest|[0-9]*)
	if [ "$arg" = latest ]; then
		file=$(gh api "repos/$REPO/contents/reports" --jq '[.[] | select(.name | endswith(".age"))] | sort_by(.name) | last | .name')
	else
		file=$(gh api "repos/$REPO/issues/$arg" --jq '.body' | sed -n 's#.*/reports/\([^ )]*\.age\).*#\1#p' | head -1)
		if [ -z "$file" ]; then
			url=$(gh api "repos/$REPO/issues/$arg/comments" --jq '.[].body' | grep -o 'https://[^ ]*' | head -1)
			[ -n "$url" ] || { echo "no archive linked from issue #$arg" >&2; exit 1; }
			enc=$dest/${url##*/}
			curl -fsSL -o "$enc" "$url"
		fi
	fi
	if [ -n "${file:-}" ]; then
		enc=$dest/$file
		gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/reports/$file" >"$enc"
	fi ;;
*)
	echo "usage: $0 ISSUE_NUMBER | latest | FILE.age" >&2; exit 2 ;;
esac

tgz=$dest/$(basename "$enc" .age)
case $tgz in *.tar.gz) ;; *) tgz=$tgz.tar.gz ;; esac
if command -v age >/dev/null 2>&1; then
	age -d -i "$KEY" -o "$tgz" "$enc"
else
	docker run --rm -i -v "$KEY:/key:ro" alpine:3.24 sh -c \
		'apk add -q age >/dev/null 2>&1 && age -d -i /key' <"$enc" >"$tgz"
fi
tar xzf "$tgz" -C "$dest"
dir=$dest/$(tar tzf "$tgz" | head -1 | cut -d/ -f1)
echo "Decrypted: $dir"
echo
cat "$dir/summary.txt"
