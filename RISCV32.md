# riscv32 package status

Failure classes: Alpine, upstream package, RV32, toolchain, kernel, board, memory.

| Package | Status | Class | Notes |
| --- | --- | --- | --- |
| binutils | cross built (step 8), native built (step 9) | Alpine | 2.45.1-r1 binutils-riscv32 (0005); no gold on riscv32 (native builds only); `_alpine_archs` left alone, riscv32 is not official |
| gcc | cross built (step 8), native built (step 9) | Alpine | 15.2.0-r9 gcc-riscv32, g++-riscv32 (0002); `rv32imac_zicsr_zifencei` / `ilp32`, autolink libatomic; D, libitm, Ada off. library dirs verified plain `lib` (multilib patch 0024 works for rv32) |
| musl | built (step 8) | Alpine | 1.2.6-r5; `ARCH=riscv32` for the headers-only stage (0003) |
| linux-headers | built (step 8) | | 7.2.1-r0; `riscv*` already maps to `riscv` |
| openssl | built (step 9), rebuilt natively (step 11) | Alpine | 3.5.9; target `linux32-riscv32` (0004; exists in 3.5, links libatomic). The cross build adds `no-threads` (APKBUILD: `CBUILD != CHOST`), which python3 refuses; rebuilt natively with `abuild -rf` before python3, as Alpine's bootstrap does. Same version, so installed copies are replaced by adding the .apk files (`apk fix` skips them) |
| busybox | built (step 9), patched (0006) | RV32 | 1.38.0: `util-linux/hwclock.c` calls `syscall(SYS_settimeofday)` to set the kernel timezone. riscv32 is time64-only, so the kernel has no settimeofday syscall and musl defines no `SYS_settimeofday`. Patch `0043-hwclock-no-settimeofday-syscall-on-riscv32.patch` makes that step a no-op there, so `hwclock -s` still sets the clock. Buildroot's patch for the same error returns failure instead, which stops `hwclock -s` |
| apk-tools | built (step 9) | | 3.0.8-r0; arch detection already handles rv32 |
| openrc | built (step 9) | | 0.63.2-r1, no change needed |
| alpine-baselayout | built (step 9) | | 3.7.2-r1, no change needed |
| alpine-base | built (step 9) | | 3.25.0_alpha20260805-r0, no change needed |
| libucontext | built (step 8) | | 1.5.2-r0, no change needed |
| everything else in bootstrap.sh's list (zlib, pkgconf, gmp, mpfr4, mpc1, isl26, zstd, make, file, patch, build-base, ca-certificates, libmd, bsd-compat-headers, libbsd, libcap, alpine-conf, alpine-keys, attr, acl, fakeroot, tar, pax-utils, lzip, abuild) | built (step 9) | | no change needed; after step 9 the riscv32 repository holds 156 files |
| ncurses, nano | native build (step 11) | | ncurses 6.6_p20260822-r0, nano 9.2-r0; built with `abuild -r` in a riscv32 container under qemu-user, no change needed |
| dropbear and its build chain (skalibs, execline, s6, utmps, bzip2, tzdata, perl, texinfo, m4, autoconf, automake) | native build (step 11) | | dropbear 2026.94-r0, perl 5.44.0-r0, utmps 0.1.3.4-r0; no change needed; tests skipped (`ABUILD_BOOTSTRAP=1`): m4's checkdepends (diffutils) is not built. dropbear accepts SSH logins in the QEMU VM |
| python3 and its libraries (expat, bluez-headers, libffi, mpdecimal, chrpath, readline, sqlite, tcl, diffutils, help2man, libtool, gettext-tiny, xz) | native build (step 11, section 8) | | python3 3.14.8-r0; no change needed; needs the natively rebuilt openssl |
| htop | patched (0008), native build (step 11) | Alpine | 3.5.3-r0; without lm-sensors when bootstrapping. Chain: bison, flex, bash, lsof |
| vim | patched (0007), native build (step 11) | Alpine | 9.2.1091-r0; no gvim and no script interfaces when bootstrapping |
| neofetch | native build (step 11) | | 7.1.0-r3 (`testing/`), bash script, no change needed |
| glib | patched (0009), native build (step 11) | Alpine | 2.90.0-r0; no man pages, DocBook tools or `glib-doc` when bootstrapping |
| e2fsprogs | patched (0010), native build (step 11) | Alpine | 1.47.4-r0; without `fuse2fs` (fuse3 chain) when bootstrapping |
| util-linux | patched (0011), native build (step 11) | Alpine | 2.42.4-r2; its bootstrap gate dropped utmps, but Alpine's musl `<paths.h>` has no `_PATH_WTMP` without it (`last.c` failed); utmps stays in every build |
| pcre2 | patched (0012), native build (step 11) | Alpine (board) | 10.49-r1; no JIT on riscv32: JIT code dies with SIGILL on the ESP32-S31 (instruction cache not synchronised with freshly written code, inferred); the interpreter works |
| mc | native build (step 11) | | 4.8.33-r3, no change needed once glib and e2fsprogs build. Chain: libedit, pcre2, swig, libcap-ng, util-linux (0011), gawk, libxml2, libunistring, gettext, py3-installer, py3-flit-core, py3-gpep517, py3-parsing, py3-packaging, samurai, py3-setuptools, py3-wheel, meson, libssh2, libpng, oniguruma, slang, gpm |
| wpa_supplicant | patched (0013), native build pending | Alpine | 2.11-r4; no D-Bus control interface and no PC/SC when bootstrapping. Needs libnl3 |
| tmux, less, tree, ncdu, btop, rsync, dtc, i2c-tools, evtest, memtester, dosfstools, exfatprogs, iw, wireless-regdb, iperf3, ethtool, socat, lua5.4 | native build pending (step 11, section 8) | | no change needed. Libraries and build tools: libevent, coreutils, bmake, lowdown, libidn2, lz4, popt, xxhash, musl-fts, libnl3, libmnl |
| curl, iproute2, strace, gdb | deferred | | natively they need about 145 more source packages (python3, cmake with its sphinx manual, elfutils, util-linux, glib); waits for patches that drop documentation-only and optional dependencies when bootstrapping |
| bootstrap.sh | patched (0001) | Alpine | key path from `ABUILD_USERDIR` (generic bug); libatomic dependency for riscv32; its default list lacks mdev-conf, which alpine-base needs (generic gap, built by hand in step 9) |
