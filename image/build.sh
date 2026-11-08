#!/bin/sh
# Build the NUC Display Lab USB survey image inside an x86_64 Alpine container.
#
# Output: out/nuclab-survey-<version>.img (+ .img.gz), a raw GPT disk image with
# one FAT32 partition labelled NUCLAB. It boots by UEFI only.
#
# Report notifications go to an ntfy.sh topic. The topic name is kept in
# image/local.conf (git-ignored) and is generated on the first build.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
alpine_tag=${ALPINE_TAG:-3.24}

if [ ! -f "$here/local.conf" ]; then
	topic="nuclab-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 20)"
	umask 077
	cat >"$here/local.conf" <<EOF
# Local build settings, baked into the image. Not committed.
#
# GitHub (primary): each report becomes an issue in GITHUB_REPO and the full
# archive is committed under reports/. Use a dedicated PRIVATE repo and a
# fine-grained token limited to that repo with only
#   Issues: Read and write, Contents: Read and write
# and a short expiry. Anyone holding the image can extract this token.
GITHUB_REPO=dangerouslaser/nuclab-reports
GITHUB_TOKEN=

# ntfy (secondary): a push notification with the summary and links. The topic
# name is the only thing keeping it private.
NTFY_SERVER=https://ntfy.sh
NTFY_TOPIC=$topic

# Temporary public file host used only when GitHub upload is unavailable.
FALLBACK_UPLOAD=litterbox
EOF
	echo "Created $here/local.conf. Add GITHUB_TOKEN there, then rebuild."
fi

version=${NUCLAB_VERSION:-$(git -C "$repo" describe --always --dirty 2>/dev/null || echo unknown)}
mkdir -p "$repo/out"

variant=${NUCLAB_VARIANT:-survey}
docker run --rm --platform linux/amd64 \
	-e NUCLAB_VERSION="$version" -e NUCLAB_VARIANT="$variant" \
	-v "$repo:/src:ro" \
	-v "$repo/out:/out" \
	"alpine:$alpine_tag" /bin/sh /src/image/scripts/build-image.sh

. "$here/local.conf"
echo
echo "Image:       $repo/out/nuclab-$variant.img.gz"
if [ -n "${GITHUB_TOKEN:-}" ]; then
	echo "GitHub:      issues in https://github.com/$GITHUB_REPO/issues"
else
	echo "GitHub:      DISABLED (no GITHUB_TOKEN in image/local.conf); archives go to ${FALLBACK_UPLOAD:-litterbox}"
fi
echo "Notify:      $NTFY_SERVER/$NTFY_TOPIC (open in a browser or the ntfy app)"
