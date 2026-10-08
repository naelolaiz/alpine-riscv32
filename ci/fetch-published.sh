#!/bin/bash
# Download the packages a previous run published, so abuild finds them in
# its repository directory and skips everything that is already up to date.
#
# usage: ci/fetch-published.sh URL DIR
#   URL  the published repository, e.g. https://OWNER.github.io/alpine-riscv32
#   DIR  abuild's REPODEST, e.g. .local/share/abuild
#
# The publish job writes files.txt, one path per line, because a static
# site has no directory listings to discover the files from.

set -euo pipefail

url=${1%/}
dest=$2
list=$(mktemp)

# 404 means nothing was published yet. Any other error stops the run: going
# on would rebuild everything and publish a smaller repository over the old.
code=$(curl -sSL --retry 3 -o "$list" -w '%{http_code}' "$url/files.txt")
case $code in
200) ;;
404)
	echo "Nothing published at $url yet: starting from an empty repository"
	exit 0 ;;
*)
	echo "::error::$url/files.txt answered HTTP $code"
	exit 1 ;;
esac

# Only repository files (REPO/ARCH/FILE), and nothing that climbs out of DIR
grep -E '^[A-Za-z0-9._+-]+/[A-Za-z0-9_]+/[A-Za-z0-9._+-]+\.(apk|tar\.gz)$' "$list" |
	grep -v -E '(^|/)\.\.?/' > "$list.repo" || true

echo "Downloading $(wc -l < "$list.repo") files from $url"
xargs -P 8 -I{} curl -fsSL --retry 3 --create-dirs -o "$dest/{}" "$url/{}" < "$list.repo"
