#!/bin/bash
# Publish the riscv32 repositories as a GitHub release, in the layout of
# the first release (packages-2026-10-10, made by hand):
#   alpine-riscv32-packages-DATE.tar.gz  main, community and testing for
#                                        riscv32, each with its APKINDEX
#   *.rsa.pub                            every key that signs something in it
#   packages.txt                         "name version repository", sorted
# The workflow runs this for a pushed packages-* tag, after building
# everything from scratch; the release gets the tag's name.
#
# usage: ci/make-release.sh REPODIR
#   REPODIR  abuild's REPODEST as the last native part left it
# Needs GH_TOKEN with contents: write, GITHUB_REPOSITORY, GITHUB_REF_NAME
# (the tag) and GITHUB_SHA.

set -euo pipefail

src=$(realpath "$1")
repo=${GITHUB_REPOSITORY:?}
tag=${GITHUB_REF_NAME:?}
if gh release view "$tag" --repo "$repo" > /dev/null 2>&1; then
	echo "::error::Release $tag exists already; push a new tag instead"
	exit 1
fi
out=$(mktemp -d)
cd "$out"

# The riscv32 repositories that have an index
repos=()
for r in main community testing; do
	[ -f "$src/$r/riscv32/APKINDEX.tar.gz" ] && repos+=("$r/riscv32")
done
[ ${#repos[@]} -gt 0 ] || { echo "No riscv32 index in $src"; exit 1; }

# packages.txt from the signed indexes: P: is the name, V: the version
for r in "${repos[@]}"; do
	tar -xzOf "$src/$r/APKINDEX.tar.gz" APKINDEX |
		awk -F: -v r="${r%/riscv32}" '/^P:/ { p = $2 } /^V:/ { print p, $2, r }'
done | sort > packages.txt
echo "$(wc -l < packages.txt) packages in ${repos[*]}"

# The release before this one, for the list of changes
prev=$(gh api "repos/$repo/releases?per_page=100" \
	--jq "[.[] | select(.draft | not) | select(.tag_name | startswith(\"packages-\")) | select(.tag_name != \"$tag\")] | sort_by(.created_at) | last | .tag_name // empty")
: > previous.txt
if [ -n "$prev" ]; then
	gh release download "$prev" --repo "$repo" --pattern packages.txt --output previous.txt --clobber || true
	sort -o previous.txt previous.txt
fi

archive=alpine-riscv32-packages-${tag#packages-}.tar.gz

# Owned by root in the archive, not by the runner's user
tar -C "$src" --owner=0 --group=0 --numeric-owner -czf "$archive" "${repos[@]}"
cp -- "$src"/*.rsa.pub .

# What changed, as "name version" lines: new or rebuilt ones, then gone ones
cut -d' ' -f1,2 previous.txt | sort > old.nv
cut -d' ' -f1,2 packages.txt | sort > new.nv
comm -13 old.nv new.nv > added.nv
comm -23 old.nv new.nv > removed.nv

commit=$(cat "$GITHUB_WORKSPACE/alpine-riscv32/aports.commit")
p=("$GITHUB_WORKSPACE"/alpine-riscv32/patches/*.patch)
first=${p[0]##*/} last=${p[-1]##*/}
names=
for r in "${repos[@]}"; do names+="${names:+, }${r%/riscv32}"; done
keys=
for k in *.rsa.pub; do keys+="${keys:+, }\`$k\`"; done

{
	echo "Alpine Linux packages for 32-bit RISC-V (riscv32: rv32imac, ilp32 soft-float, musl), built from scratch by GitHub Actions for tag $tag (commit ${GITHUB_SHA:0:7}): aports commit ${commit:0:7} with patches ${first%%-*} to ${last%%-*} from this repository applied."
	echo
	echo "## New or rebuilt since ${prev:-the start}"
	echo
	if [ -s added.nv ]; then sed 's/^/- /' added.nv; else echo "None."; fi
	if [ -s removed.nv ]; then
		echo
		echo "## No longer in the repositories"
		echo
		sed 's/^/- /' removed.nv
	fi
	echo
	echo "## Files"
	echo
	echo "- \`$archive\` holds the riscv32 repositories $names, each with its signed \`APKINDEX.tar.gz\`."
	echo "- $keys: the public keys that sign the packages and indexes. Packages carried over from an earlier release keep the key they were signed with."
	echo "- \`packages.txt\` lists every package in the archive, with its version and repository."
	echo
	cat <<EOF
## Install on a board

On the PC, with the board's root file system (the stick) mounted at \`/mnt\`, in the directory that holds the downloaded files. The keys let apk verify the signatures; removing the old \`/root/repo\` drops the packages this release replaces.

\`\`\`
sudo cp ./*.rsa.pub /mnt/etc/apk/keys/
sudo rm -rf /mnt/root/repo
sudo mkdir -p /mnt/root/repo
sudo tar -xzf $archive -C /mnt/root/repo
\`\`\`

Then on the board, as root. The first line is needed once: with the three directories in \`/etc/apk/repositories\`, plain \`apk add\` and \`apk upgrade\` use them.

\`\`\`
printf '/root/repo/main\n/root/repo/community\n/root/repo/testing\n' > /etc/apk/repositories
apk upgrade
apk add htop
\`\`\`

A board with network can list https://${GITHUB_REPOSITORY_OWNER,,}.github.io/${repo#*/}/main (and \`/community\`, \`/testing\`) in \`/etc/apk/repositories\` instead: the workflow updates that site on every build on main.

EOF
	echo "These are unofficial packages and are not supported by Alpine Linux."
	echo
	echo "How they were built: https://github.com/$repo/blob/main/docs/steps/23-package-ci.md"
	echo "Per-package status: https://github.com/$repo/blob/main/RISCV32.md"
	echo "Workflow run: https://github.com/$repo/actions/runs/${GITHUB_RUN_ID:-}"
} > notes.md

cat notes.md
gh release create "$tag" --repo "$repo" --verify-tag \
	--title "riscv32 packages ${tag#packages-}" --notes-file notes.md \
	"$archive" ./*.rsa.pub packages.txt
