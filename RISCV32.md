# riscv32 package status

Failure classes: Alpine, upstream package, RV32, toolchain, kernel, board, memory.

| Package | Status | Class | Notes |
| --- | --- | --- | --- |
| binutils | not started | | arch lists mention only riscv64 |
| gcc | not started | | needs `riscv32-*-*-*` case: `--with-arch=rv32imac --with-abi=ilp32`; review multilib patch |
| musl | not started | | needs `riscv32` to `ARCH=riscv32` |
| linux-headers | not started | | `riscv*` already maps to `riscv` |
| openssl | not started | | needs `linux32-riscv32` target |
| busybox | not started | | |
| apk-tools | not started | | arch detection already handles rv32 |
| openrc | not started | | |
| alpine-baselayout | not started | | |
| libucontext | not started | | riscv32 support unverified |
