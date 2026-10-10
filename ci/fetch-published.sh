#!/bin/bash
# Download the packages published so far, so abuild finds them in its
# repository directory and skips everything that is already up to date.
# The source is the Pages site the previous run deployed; while it has
# nothing yet, the newest packages-* release (which may have been made by
# hand, from packages built on a PC). The keys come along, because
# packages carried over keep the key they were signed with.
#
# usage: ci/fetch-published.sh URL DIR
#   URL  the Pages site, e.g. https://OWNER.github.io/alpine-riscv32
#   DIR  abuild's REPODEST, e.g. .local/share/abuild
# Needs GH_TOKEN and GITHUB_REPOSITORY for the release fallback.
#
# The pages job writes files.txt, one path per line, because a static site
# has no directory listings to discover the files from.

set -euo pipefail

url=${1%/}
dest=$2
list=$(mktemp)
mkdir -p "$dest"

from_release() {
	local repo=${GITHUB_REPOSITORY:?} tag dl t
	tag=$(gh api "repos/$repo/releases?per_page=100" \
		--jq '[.[] | select(.draft | not) | select(.tag_name | startswith("packages-"))] | sort_by(.created_at) | last | .tag_name // empty')
	if [ -z "$tag" ]; then
		echo "No packages-* release either: starting from an empty repository"
		return 0
	fi
	dl=$(mktemp -d)
	echo "Downloading release $tag"
	gh release download "$tag" --repo "$repo" --dir "$dl" --pattern '*.tar.gz' --pattern '*.rsa.pub'
	for t in "$dl"/*.tar.gz; do
		tar -xzf "$t" --no-same-owner -C "$dest"
	done
	# -n: the key of this run (prepare.sh) wins over a file of the same name
	cp -n -- "$dl"/*.rsa.pub "$dest"/
}

# 404 means nothing was deployed yet. Any other error stops the run: going
# on would rebuild everything and deploy a smaller repository over the old.
code=$(curl -sSL --retry 3 -o "$list" -w '%{http_code}' "$url/files.txt")
case $code in
200) ;;
404)
	echo "Nothing on $url yet: trying the releases"
	from_release
	exit 0 ;;
*)
	echo "::error::$url/files.txt answered HTTP $code"
	exit 1 ;;
esac

# Only repository files (REPO/ARCH/FILE) and keys at the top, and nothing
# that climbs out of DIR
grep -E -e '^[A-Za-z0-9._+-]+/[A-Za-z0-9_]+/[A-Za-z0-9._+-]+\.(apk|tar\.gz)$' \
	-e '^[A-Za-z0-9._+-]+\.rsa\.pub$' "$list" |
	grep -v -E '(^|/)\.\.?/' > "$list.repo" || true
# The key of this run (prepare.sh) is already there; keep it
find "$dest" -maxdepth 1 -name '*.rsa.pub' -printf '%f\n' > "$list.have"
grep -v -x -F -f "$list.have" "$list.repo" > "$list.get" || true

echo "Downloading $(wc -l < "$list.get") files from $url"
xargs -P 8 -I{} curl -fsSL --retry 3 --create-dirs -o "$dest/{}" "$url/{}" < "$list.get"
