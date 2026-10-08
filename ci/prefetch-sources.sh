#!/bin/bash
# Download the sources listed in ci/sources.txt into SRCDEST, unless a
# restored cache already has them. abuild then finds them there and only
# checks their sha512, as with the curl commands in steps 8, 9 and 11.

set -euo pipefail

sed -e 's/#.*//' alpine-riscv32/ci/sources.txt | while read -r file url; do
	[ -n "$file" ] || continue
	[ -f ".cache/distfiles/$file" ] && continue
	echo "Fetching $file from $url"
	curl -fsSL --retry 3 --connect-timeout 20 -o ".cache/distfiles/$file.part" "$url"
	mv ".cache/distfiles/$file.part" ".cache/distfiles/$file"
done
