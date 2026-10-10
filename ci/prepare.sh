#!/bin/bash
# Set up a GitHub runner the way docs/steps/07-build-environment.md sets up
# a PC: aports at the pinned commit with patches/ applied, an abuild signing
# key and settings, and an Alpine edge container `alpine-rv32` with the build
# tools and a user that may run abuild.
#
# Runs on the runner, in the directory that holds this repository (checked
# out as `alpine-riscv32`). That directory is mounted at /work in every
# container, and HOME is /work there, as on the PC.
#
# The private key comes from the ABUILD_PRIVKEY environment variable (a
# repository secret). Without it, a run on a branch other than main makes a
# temporary key (or reuses the one the cross job handed over); main and
# tags refuse, because what they build gets published.

set -euo pipefail

work=$PWD
keyname=alpine-riscv32-ci.rsa
keydir=.config/abuild
repodest=.local/share/abuild

# 1. aports at the pinned commit, plus the series
commit=$(cat alpine-riscv32/aports.commit)
git init -q aports
# --depth 1 downloads only that commit's tree, not aports' long history
git -C aports fetch -q --depth 1 https://gitlab.alpinelinux.org/alpine/aports.git "$commit" ||
	git -C aports fetch -q --depth 1 https://github.com/alpinelinux/aports.git "$commit"
git -C aports switch -q -c riscv32 FETCH_HEAD
git -C aports -c user.name=ci -c user.email=ci@localhost am -q "$work"/alpine-riscv32/patches/*.patch
git -C aports log --oneline "$commit"..

# 2. Signing key and abuild settings
mkdir -p "$keydir" "$repodest" .cache/distfiles
temporary=true
if [ -n "${ABUILD_PRIVKEY:-}" ]; then
	(umask 077; printf '%s\n' "$ABUILD_PRIVKEY" > "$keydir/$keyname")
	temporary=false
elif [ "${GITHUB_REF:-}" = refs/heads/main ] || [ "${GITHUB_REF_TYPE:-}" = tag ]; then
	echo "::error::The repository secret ABUILD_PRIVKEY is not set; see docs/steps/23-package-ci.md, section 1"
	exit 1
elif [ -f "$keydir/$keyname" ]; then
	echo "Using the temporary key from the cross job"
else
	echo "::warning::No ABUILD_PRIVKEY secret: signing with a temporary key, building from scratch, publishing nothing"
	(umask 077; openssl genrsa -out "$keydir/$keyname" 2048 2>/dev/null)
fi
openssl rsa -in "$keydir/$keyname" -pubout -out "$keydir/$keyname.pub" 2>/dev/null
chmod 644 "$keydir/$keyname.pub"
# The public key travels with the packages, so the published repository
# carries the key that verifies it
cp "$keydir/$keyname.pub" "$repodest/"

cat > "$keydir/abuild.conf" <<EOF
PACKAGER="alpine-riscv32 CI <alpine-riscv32@users.noreply.github.com>"
PACKAGER_PRIVKEY="/work/$keydir/$keyname"
SRCDEST=/work/.cache/distfiles
DISTFILES_MIRROR=https://distfiles.alpinelinux.org/distfiles/edge
EOF

# 3. The x86_64 build container
docker run -d --name alpine-rv32 -v "$work":/work -w /work docker.io/library/alpine:edge sleep infinity
docker exec alpine-rv32 apk add -q alpine-sdk
# podman's --userns=keep-id does this on the PC: a user with the runner's uid,
# so files written in /work belong to the runner, and HOME=/work
docker exec alpine-rv32 adduser -D -H -h /work -u "$(id -u)" builder
docker exec alpine-rv32 addgroup builder abuild
docker exec alpine-rv32 cp "/work/$keydir/$keyname.pub" /etc/apk/keys/
docker exec -u builder alpine-rv32 sh -c 'echo "HOME=$HOME"; id; abuild -V'

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "temporary-key=$temporary" >> "$GITHUB_OUTPUT"
fi
