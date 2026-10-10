#!/bin/bash
# Download everything published so far, so abuild finds it in its
# repository directory and skips what is already up to date:
#   1. the Pages site the last run on main deployed;
#   2. the packages of the newest packages-* release (built from a tag, or
#      by hand on a PC), added on top. Where both have a file of the same
#      name, the release's wins: it is the build someone chose to publish.
# The keys come along, because a package keeps the key it was signed with.
#
# usage: ci/fetch-published.sh URL DIR
#   URL  the Pages site, e.g. https://OWNER.github.io/alpine-riscv32
#   DIR  abuild's REPODEST relative to the workspace (/work in the
#        container), e.g. .local/share/abuild
#
# Runs on the runner with the container alpine-rv32 up (prepare.sh). It
# makes the container trust every key, and where the release added or
# replaced packages next to Pages' ones, it writes a new index signed with
# this run's key, as abuild does after a build. Needs GH_TOKEN and
# GITHUB_REPOSITORY.

set -euo pipefail

url=${1%/}
dest=$2
repo=${GITHUB_REPOSITORY:?}
tmp=$(mktemp -d)
mkdir -p "$dest"

# 1. Pages. The pages job writes files.txt, one path per line, because a
# static site has no directory listings. 404 means nothing was deployed
# yet. Any other error stops the run: going on would rebuild everything
# and deploy a smaller repository over the old one.
code=$(curl -sSL --retry 3 -o "$tmp/files.txt" -w '%{http_code}' "$url/files.txt")
case $code in
200)
	# Only repository files (REPO/ARCH/FILE) and keys at the top, and
	# nothing that climbs out of DIR
	grep -E -e '^[A-Za-z0-9._+-]+/[A-Za-z0-9_]+/[A-Za-z0-9._+-]+\.(apk|tar\.gz)$' \
		-e '^[A-Za-z0-9._+-]+\.rsa\.pub$' "$tmp/files.txt" |
		grep -v -E '(^|/)\.\.?/' > "$tmp/repo.txt" || true
	# The key of this run (prepare.sh) is already there; keep it
	find "$dest" -maxdepth 1 -name '*.rsa.pub' -printf '%f\n' > "$tmp/have.txt"
	grep -v -x -F -f "$tmp/have.txt" "$tmp/repo.txt" > "$tmp/get.txt" || true
	echo "Downloading $(wc -l < "$tmp/get.txt") files from $url"
	xargs -P 8 -I{} curl -fsSL --retry 3 --create-dirs -o "$dest/{}" "$url/{}" < "$tmp/get.txt"
	;;
404)
	echo "Nothing on $url yet" ;;
*)
	echo "::error::$url/files.txt answered HTTP $code"
	exit 1 ;;
esac

# 2. The newest release
tag=$(gh api "repos/$repo/releases?per_page=100" \
	--jq '[.[] | select(.draft | not) | select(.tag_name | startswith("packages-"))] | sort_by(.created_at) | last | .tag_name // empty')
: > "$tmp/changed.txt"
if [ -n "$tag" ]; then
	echo "Adding the packages of release $tag"
	mkdir "$tmp/release" "$tmp/tree"
	gh release download "$tag" --repo "$repo" --dir "$tmp/release" --pattern '*.tar.gz' --pattern '*.rsa.pub'
	for t in "$tmp"/release/*.tar.gz; do
		tar -xzf "$t" --no-same-owner -C "$tmp/tree"
	done
	# The key of this run (prepare.sh) wins over a file of the same name
	for k in "$tmp"/release/*.rsa.pub; do
		[ -e "$dest/${k##*/}" ] || cp -- "$k" "$dest"/
	done
	# Each package that is new or differs; its directory needs a new index
	(cd "$tmp/tree" && find . -name '*.apk' -printf '%P\n') | while read -r f; do
		if ! cmp -s "$tmp/tree/$f" "$dest/$f"; then
			mkdir -p "$dest/${f%/*}"
			cp -- "$tmp/tree/$f" "$dest/$f"
			echo "${f%/*}"
		fi
	done | sort -u > "$tmp/changed.txt"
	echo "$(wc -l < "$tmp/changed.txt") directories changed by the release"
	rm -rf "$tmp/tree" "$tmp/release"
fi

# 3. Trust every key: apk checks each package's own signature, and
# bootstrap.sh copies /etc/apk/keys into its sysroot
docker exec alpine-rv32 sh -c "cp /work/$dest/*.rsa.pub /etc/apk/keys/ && ls /etc/apk/keys/"

# 4. New indexes where the release changed something, written the way
# abuild writes them (apk index, then abuild-sign with this run's key)
while read -r d; do
	echo "New index for $d"
	docker exec -u builder -w "/work/$dest/$d" alpine-rv32 sh -c \
		'apk index --quiet --rewrite-arch "${PWD##*/}" --description "$1 (alpine-riscv32 CI)" -o APKINDEX.tar.gz.new ./*.apk &&
		abuild-sign -q APKINDEX.tar.gz.new && mv APKINDEX.tar.gz.new APKINDEX.tar.gz' sh "$d"
done < "$tmp/changed.txt"

find "$dest" -name '*.apk' | wc -l
