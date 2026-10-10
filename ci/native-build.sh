#!/bin/bash
# Build every package in ci/native-packages.txt, in order, inside the riscv32
# container `rv32-native`, as docs/steps/11-native-build.md does by hand.
#
# Runs on the runner, in the directory mounted at /work. A package that
# fails does not stop the loop: later packages that do not need it still get
# built and published. When BUDGET_MINUTES is used up, the rest are left for
# the next run, which skips everything this one finished.

set -uo pipefail

list=alpine-riscv32/ci/native-packages.txt
deadline=$(( $(date +%s) + ${BUDGET_MINUTES:-300} * 60 ))
built=() failed=() left=()

# openssl from bootstrap.sh has no thread support: its APKBUILD adds
# no-threads when cross building (step 11, section 8). The check reads the
# header that says so from the package in the repository.
cross_openssl() {
	docker exec alpine-rv32 sh -c 'for f in /work/.local/share/abuild/main/riscv32/openssl-dev-[0-9]*.apk; do tar -xzOf "$f" usr/include/openssl/configuration.h 2>/dev/null; done' |
		grep -q OPENSSL_NO_THREADS
}

while read -r p opt _; do
	[ -n "$p" ] || continue
	if [ "$(date +%s)" -ge "$deadline" ]; then
		left+=("$p")
		continue
	fi
	echo "::group::$p"
	start=$(date +%s)
	# -f builds even though a package of the same version exists
	force=
	if [ "$opt" = rebuild-if-cross ] && cross_openssl; then
		echo "$p in the repository is the cross build: building it again natively"
		force=-f
	fi
	# ABUILD_BOOTSTRAP=1 skips check() (tests run under emulation and some
	# checkdepends are not built); APORTS_BOOTSTRAP=1 switches on the
	# APKBUILD trims in patches/
	if docker exec -u builder -w "/work/aports/$p" \
		-e ABUILD_BOOTSTRAP=1 -e APORTS_BOOTSTRAP=1 \
		rv32-native abuild -r $force; then
		built+=("$p, $(( ($(date +%s) - start) / 60 )) min")
		# Same version, new build: apk only takes it from the file, and
		# the container's libraries must be the new ones for python3.
		# del drops the file names from world again (step 11, section 8)
		if [ -n "$force" ]; then
			docker exec -u builder -w "/work/aports/$p" rv32-native sh -c \
				'. ./APKBUILD && d=/work/.local/share/abuild/main/riscv32 &&
				abuild-apk add "$d/libcrypto3-$pkgver-r$pkgrel.apk" "$d/libssl3-$pkgver-r$pkgrel.apk" &&
				abuild-apk del libcrypto3 libssl3' ||
				{ failed+=("$p (installing its new libraries)"); echo "::error::$p: installing its new libraries failed"; }
		fi
	else
		failed+=("$p")
		echo "::error::$p failed"
	fi
	echo "::endgroup::"
done < <(sed -e 's/#.*//' "$list")

{
	echo "## Native riscv32 builds"
	echo
	echo "Built or already up to date: ${#built[@]}"
	for p in "${built[@]}"; do echo "- $p"; done
	if [ ${#failed[@]} -gt 0 ]; then
		echo
		echo "Failed: ${#failed[@]}"
		for p in "${failed[@]}"; do echo "- $p"; done
	fi
	if [ ${#left[@]} -gt 0 ]; then
		echo
		echo "Not started, time budget used up (run the workflow again to continue): ${#left[@]}"
		for p in "${left[@]}"; do echo "- $p"; done
	fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# The release job runs only when nothing was left
echo "left=${#left[@]}" >> "${GITHUB_OUTPUT:-/dev/null}"
[ ${#left[@]} -eq 0 ] || echo "::warning::${#left[@]} packages left for the next run"
[ ${#failed[@]} -eq 0 ]
