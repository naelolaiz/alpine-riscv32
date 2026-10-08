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

while read -r p _; do
	[ -n "$p" ] || continue
	if [ "$(date +%s)" -ge "$deadline" ]; then
		left+=("$p")
		continue
	fi
	echo "::group::$p"
	start=$(date +%s)
	# ABUILD_BOOTSTRAP=1 skips check() (tests run under emulation and some
	# checkdepends are not built); APORTS_BOOTSTRAP=1 switches on the
	# APKBUILD trims in patches/
	if docker exec -u builder -w "/work/aports/$p" \
		-e ABUILD_BOOTSTRAP=1 -e APORTS_BOOTSTRAP=1 \
		rv32-native abuild -r; then
		built+=("$p, $(( ($(date +%s) - start) / 60 )) min")
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

[ ${#left[@]} -eq 0 ] || echo "::warning::${#left[@]} packages left for the next run"
[ ${#failed[@]} -eq 0 ]
