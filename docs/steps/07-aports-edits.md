# Step 7, part 2: the riscv32 edits to aports

**Everything in part 2 runs on the HOST**, in the directory that holds
`aports`, `alpine-riscv32` and `esp32s31-alpine` (the one mounted at `/work`).
Nothing runs in the container until step 8.

Edits to the aports checkout from part 1 (branch `riscv32`, at the commit in
[`aports.commit`](../../aports.commit)), made by hand on the host with any
editor; the container sees them through `/work`. Line numbers are for that
commit. Indentation in these files is tabs; keep it. Inside one file, edit
from the bottom up, because inserted lines shift the line numbers below them.
Each file is one commit, so the series can be exported as patches and
reviewed or upstreamed one by one.

Versions at this commit: gcc 15.2.0, musl 1.2.6, binutils 2.45.1, openssl 3.5.9.

## 0. A git identity for aports

HOST:

```sh
git -C aports config user.name "naelolaiz"
git -C aports config user.email "1333555+naelolaiz@users.noreply.github.com"
```

The commits become patch files in this repository, and a patch carries its
author's name and e-mail. GitHub's no-reply address links the patches to the
GitHub account without publishing a private e-mail address.

## 1. bootstrap.sh: the key directory (generic fix)

`scripts/bootstrap.sh` line 93:

```diff
-	cp -a ~/.abuild/*.pub "$CBUILDROOT/etc/apk/keys"
+	cp -a "$ABUILD_USERDIR"/*.pub "$CBUILDROOT/etc/apk/keys"
```

abuild 3.x keeps its user files in `~/.config/abuild` (or `~/.abuild` if only
that exists) and exports the choice as `ABUILD_USERDIR` from `functions.sh`,
which the script sources earlier. With a fresh key the old path matches
nothing, `cp` fails and `set -e` stops the bootstrap before anything is built.

## 2. bootstrap.sh: libatomic for riscv32

Line 142:

```diff
-if [ "$CTARGET_ARCH" = "riscv64" ]; then
+if [ "$CTARGET_ARCH" = "riscv64" ] || [ "$CTARGET_ARCH" = "riscv32" ]; then
```

The A extension gives atomic instructions only up to the register width. On
rv32, every 64-bit atomic (common in C++ `<atomic>` and in OpenSSL) becomes a
call into libatomic, which lives in the gcc package. This makes the
cross-built target gcc an implicit dependency of every later package, so
libatomic is in the sysroot when they link.

Commit (both bootstrap.sh fixes together): `scripts/bootstrap.sh: copy keys from ABUILD_USERDIR, riscv32 needs libatomic`

## 3. gcc: CPU, ABI and unsupported runtimes

`main/gcc/APKBUILD`, line 306, add a line after the riscv64 one:

```diff
 	riscv64-*-*-*)		_arch_configure="--with-arch=rv64gc --with-abi=lp64d --enable-autolink-libatomic";;
+	riscv32-*-*-*)		_arch_configure="--with-arch=rv32imac_zicsr_zifencei --with-abi=ilp32 --enable-autolink-libatomic";;
```

- `--with-arch`: the default `-march` of the compiler, the instructions it may
  emit. `rv32imac` is the base most RV32 Linux cores share. (The ESP32-S31's stock
  kernel reports `rv32imac_zicsr_zifencei_...`; the core does have F, without
  D, but that kernel drops F because it lacks D. Found later, in
  `esp32s31-alpine` step 20.)
  Since the 2019 ISA spec, CSR access (`zicsr`) and `fence.i` (`zifencei`) are
  separate extensions; `rv64gc` includes them through `g`, `rv32imac` does not,
  so without them any code using CSR instructions fails to assemble.
- `--with-abi=ilp32`: int, long and pointers are 32 bit, floating-point values
  are passed in integer registers (soft-float). It is the only ABI that runs
  on cores without an FPU, and the one Espressif's toolchain uses. Why it
  stays so on the S31's F: README, "Why soft-float".
- `--enable-autolink-libatomic`: gcc adds `-latomic` (as needed) by itself,
  for the same reason as edit 2.

Line 122, the D language:

```diff
-ppc*|riscv64)	LANG_D=false ;;
+ppc*|riscv32|riscv64)	LANG_D=false ;;
```

The comment above it says the D runtime is not implemented for RISC-V, and
the next case notes that D does not work on 32-bit musl at all.

Line 133, add after the riscv64 line:

```diff
 riscv64)	_libitm=false ;;
+riscv32)	_libitm=false ;;
```

libitm (transactional memory) is disabled on riscv64 too.

Also add riscv32 to the Ada switch. There is no per-architecture Ada case, so
add one after the libitm case:

```diff
+# Ada is not needed for the riscv32 base system; keep the first bootstrap small
+case "$CTARGET_ARCH" in
+riscv32)	LANG_ADA=false ;;
+esac
```

The base system needs only C and C++. Ada's runtime on 32-bit RISC-V is
untested here, and a failure would come late in a long gcc build.

Commit: `main/gcc: add riscv32`

Left as is: patch `0024-riscv-disable-multilib-support.patch` pins library
directories to `lib` for rv64gc. With `--disable-multilib` it should also give
`lib` on rv32; step 8 checks it with `riscv32-alpine-linux-musl-gcc
-print-multi-os-directory` and `-print-search-dirs` (no `lib32/ilp32`).

## 4. musl: the arch name for the headers stage

`main/musl/APKBUILD`, line 114, add after the riscv64 line:

```diff
 	riscv64)	ARCH="riscv64" ;;
+	riscv32)	ARCH="riscv32" ;;
```

In the first bootstrap stage (`BOOTSTRAP=nocc`) no cross compiler exists yet,
so musl cannot detect the architecture and only installs headers for the
`ARCH` it is given. Later stages detect it from the compiler. musl supports
riscv32 since 1.2.5, with 64-bit `time_t` only.

Commit: `main/musl: add riscv32`

## 5. openssl: the target name

`main/openssl/APKBUILD`, line 206, add after the riscv64 line:

```diff
 		riscv64)	target="linux64-riscv64";;
+		riscv32)	target="linux32-riscv32";;
```

OpenSSL's `Configure` has its own target names
(`Configurations/10-main.conf`); 3.5 defines `linux32-riscv32`, which also
links libatomic. Without the line the `*)` case stops the build.

Commit: `main/openssl: add riscv32`

## 6. binutils: no gold on riscv32

`main/binutils/APKBUILD`, line 58:

```diff
-if [ "$CHOST" = "$CBUILD" ] && [ "$CBUILD" = "$CTARGET" ] && [ "$CTARGET_ARCH" != "riscv64" ] && [ "$CTARGET_ARCH" != "loongarch64" ]; then
+if [ "$CHOST" = "$CBUILD" ] && [ "$CBUILD" = "$CTARGET" ] && [ "$CTARGET_ARCH" != "riscv64" ] && [ "$CTARGET_ARCH" != "riscv32" ] && [ "$CTARGET_ARCH" != "loongarch64" ]; then
```

The gold linker does not support RISC-V. The condition is true only for a
native build (built on riscv32, for riscv32), so this matters from step 11
on, not for the cross bootstrap.

Left as is: `_alpine_archs` (line 23) lists the official Alpine
architectures, for which a native binutils also builds cross binutils.
riscv32 is not official, so it does not belong there yet.

Commit: `main/binutils: no gold on riscv32`

## 7. Commit and export

HOST, in the directory holding `aports`. One commit per file;
`git commit -m "..." <file>` commits only that file, and with `-C aports` the
path is relative to `aports`:

```sh
git -C aports status --short
git -C aports commit -m "scripts/bootstrap.sh: copy keys from ABUILD_USERDIR, riscv32 needs libatomic" scripts/bootstrap.sh
git -C aports commit -m "main/gcc: add riscv32" main/gcc/APKBUILD
git -C aports commit -m "main/musl: add riscv32" main/musl/APKBUILD
git -C aports commit -m "main/openssl: add riscv32" main/openssl/APKBUILD
git -C aports commit -m "main/binutils: no gold on riscv32" main/binutils/APKBUILD
git -C aports log --oneline $(cat alpine-riscv32/aports.commit)..
```

`status --short` must list exactly those five files as modified.

Export the series, HOST, same directory:

```sh
git -C aports format-patch -o ../alpine-riscv32/patches $(cat alpine-riscv32/aports.commit)..
```

`format-patch` writes one numbered file per commit; `git am` on a fresh
checkout of the pinned commit re-creates the branch.

Done when: five commits on `riscv32`, exported to `patches/`.
Next: step 8, `scripts/bootstrap.sh riscv32` up to the cross gcc and musl.
