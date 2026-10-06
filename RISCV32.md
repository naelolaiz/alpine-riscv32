# riscv32 package status

Failure classes: Alpine, upstream package, RV32, toolchain, kernel, board, memory.

| Package | Status | Class | Notes |
| --- | --- | --- | --- |
| binutils | patched (0005) | Alpine | no gold on riscv32 (native builds only); `_alpine_archs` left alone, riscv32 is not official |
| gcc | patched (0002) | Alpine | `rv32imac_zicsr_zifencei` / `ilp32`, autolink libatomic; D, libitm, Ada off. Check multilib dir in step 8 |
| musl | patched (0003) | Alpine | `ARCH=riscv32` for the headers-only stage |
| linux-headers | not started | | `riscv*` already maps to `riscv` |
| openssl | patched (0004) | Alpine | target `linux32-riscv32` (exists in 3.5, links libatomic) |
| busybox | not started | | |
| apk-tools | not started | | arch detection already handles rv32 |
| openrc | not started | | |
| alpine-baselayout | not started | | |
| libucontext | no change expected | | upstream has `arch/riscv32`; aports passes `ARCH=$CARCH` |
| bootstrap.sh | patched (0001) | Alpine | key path from `ABUILD_USERDIR` (generic bug); libatomic dependency for riscv32 |
