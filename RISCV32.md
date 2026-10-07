# riscv32 package status

Failure classes: Alpine, upstream package, RV32, toolchain, kernel, board, memory.

| Package | Status | Class | Notes |
| --- | --- | --- | --- |
| binutils | cross built (step 8) | Alpine | 2.45.1-r1 binutils-riscv32 (0005); no gold on riscv32 (native builds only); `_alpine_archs` left alone, riscv32 is not official |
| gcc | cross built (step 8) | Alpine | 15.2.0-r9 gcc-riscv32, g++-riscv32 (0002); `rv32imac_zicsr_zifencei` / `ilp32`, autolink libatomic; D, libitm, Ada off. library dirs verified plain `lib` (multilib patch 0024 works for rv32) |
| musl | built (step 8) | Alpine | 1.2.6-r5; `ARCH=riscv32` for the headers-only stage (0003) |
| linux-headers | built (step 8) | | 7.2.1-r0; `riscv*` already maps to `riscv` |
| openssl | patched (0004) | Alpine | target `linux32-riscv32` (exists in 3.5, links libatomic) |
| busybox | not started | | |
| apk-tools | not started | | arch detection already handles rv32 |
| openrc | not started | | |
| alpine-baselayout | not started | | |
| libucontext | built (step 8) | | 1.5.2-r0, no change needed |
| bootstrap.sh | patched (0001) | Alpine | key path from `ABUILD_USERDIR` (generic bug); libatomic dependency for riscv32 |
