# riscv32 package status

Failure classes: Alpine, upstream package, RV32, toolchain, kernel, board, memory.

| Package | Status | Class | Notes |
| --- | --- | --- | --- |
| binutils | cross built (step 8), native built (step 9) | Alpine | 2.45.1-r1 binutils-riscv32 (0005); no gold on riscv32 (native builds only); `_alpine_archs` left alone, riscv32 is not official |
| gcc | cross built (step 8), native built (step 9) | Alpine | 15.2.0-r9 gcc-riscv32, g++-riscv32 (0002); `rv32imac_zicsr_zifencei` / `ilp32`, autolink libatomic; D, libitm, Ada off. library dirs verified plain `lib` (multilib patch 0024 works for rv32) |
| musl | built (step 8) | Alpine | 1.2.6-r5; `ARCH=riscv32` for the headers-only stage (0003) |
| linux-headers | built (step 8) | | 7.2.1-r0; `riscv*` already maps to `riscv` |
| openssl | built (step 9) | Alpine | 3.5.9; target `linux32-riscv32` (0004; exists in 3.5, links libatomic) |
| busybox | built (step 9), patched (0006) | RV32 | 1.38.0: `util-linux/hwclock.c` calls `syscall(SYS_settimeofday)` to set the kernel timezone. riscv32 is time64-only, so the kernel has no settimeofday syscall and musl defines no `SYS_settimeofday`. Patch `0043-hwclock-no-settimeofday-syscall-on-riscv32.patch` makes that step a no-op there, so `hwclock -s` still sets the clock. Buildroot's patch for the same error returns failure instead, which stops `hwclock -s` |
| apk-tools | built (step 9) | | 3.0.8-r0; arch detection already handles rv32 |
| openrc | built (step 9) | | 0.63.2-r1, no change needed |
| alpine-baselayout | built (step 9) | | 3.7.2-r1, no change needed |
| alpine-base | built (step 9) | | 3.25.0_alpha20260805-r0, no change needed |
| libucontext | built (step 8) | | 1.5.2-r0, no change needed |
| everything else in bootstrap.sh's list (zlib, pkgconf, gmp, mpfr4, mpc1, isl26, zstd, make, file, patch, build-base, ca-certificates, libmd, bsd-compat-headers, libbsd, libcap, alpine-conf, alpine-keys, attr, acl, fakeroot, tar, pax-utils, lzip, abuild) | built (step 9) | | no change needed; after step 9 the riscv32 repository holds 156 files |
| bootstrap.sh | patched (0001) | Alpine | key path from `ABUILD_USERDIR` (generic bug); libatomic dependency for riscv32 |
