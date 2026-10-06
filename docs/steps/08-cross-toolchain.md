# Step 8: cross toolchain and the first riscv32 packages

Runs the patched `scripts/bootstrap.sh` (step 7) far enough to get a working
riscv32 cross compiler and a riscv32 musl, then proves the result under
qemu-user.

## 0. Check the series

HOST, in the directory holding `aports`:

```sh
git -C aports log --oneline $(cat alpine-riscv32/aports.commit)..
grep -n 'linux32-riscv32' aports/main/openssl/APKBUILD
grep -n 'ABUILD_USERDIR' aports/scripts/bootstrap.sh
```

Five commits; openssl line 206 with `linux32-riscv32`; bootstrap.sh line 93
with `"$ABUILD_USERDIR"/*.pub` in quotes. The same series is in
[`patches/`](../../patches/).

## 1. What bootstrap.sh does

`bootstrap.sh riscv32 PKG...` runs `abuild` many times with different
`BOOTSTRAP=` modes:

1. Creates the riscv32 sysroot (`$HOME/sysroot-riscv32`, here
   `/work/sysroot-riscv32`): an empty apk database for arch riscv32, with
   Alpine's keys and yours.
2. Builds the cross compiler, on and for x86_64, targeting riscv32:
   `binutils-riscv32` (assembler, linker), musl headers (`BOOTSTRAP=nocc`),
   `gcc-pass2-riscv32` (C only, no libc yet), musl itself built with that
   compiler, libucontext, the full `gcc-riscv32` (C and C++, now linked
   against musl), and `build-base-riscv32`.
3. Cross-builds each `PKG` for riscv32 (`BOOTSTRAP=bootimage`) and installs
   it into the sysroot, so later packages can link against it.

Packages land in abuild's `REPODEST`, by default `~/.local/share/abuild`
(here `/work/.local/share/abuild`), signed with your key. Sources are
downloaded to `/var/cache/distfiles` in the container. With no `PKG`, step 3 is the whole base system list; this step limits it
to the first three.

## 2. Sources on the host

HOST, in the directory holding `aports`:

```sh
echo 'SRCDEST=/work/.cache/distfiles' >> .config/abuild/abuild.conf
mkdir -p .cache/distfiles
curl -fL -o .cache/distfiles/binutils-2.45.1.tar.xz https://mirrors.kernel.org/gnu/binutils/binutils-2.45.1.tar.xz
curl -fL -o .cache/distfiles/binutils-with-gold-2.44.tar.xz https://mirrors.kernel.org/gnu/binutils/binutils-with-gold-2.44.tar.xz
```

- `SRCDEST` is where abuild keeps downloaded sources. A file already there is
  not downloaded again, only checked against the APKBUILD's `sha512sums`. On
  the host it also survives recreating the container.
- `ftp.gnu.org`, binutils' source URL, often refuses connections.
  `mirrors.kernel.org/gnu` is an official GNU mirror with the same files; a
  different file would fail the checksum. gcc comes from `gcc.gnu.org`, a
  different server.
- Alpine's distfiles mirror (`DISTFILES_MIRROR`) did not have
  `binutils-2.45.1.tar.xz` (404), so it is not used.

## 3. Run it

CONTAINER, entered with `podman exec -it -u $(id -un) alpine-rv32 sh`, at its
prompt:

```sh
cd /work/aports
./scripts/bootstrap.sh riscv32 fortify-headers linux-headers musl 2>&1 | tee /work/bootstrap-step8.log
```

`tee` keeps a full log on the host as well. binutils and two gcc builds take
most of the time. Re-running is safe: abuild skips packages that are already
built and up to date. If it stops, the last 50 lines of the log say where:
`tail -n 50 /work/bootstrap-step8.log`.

## 4. Check the compiler

CONTAINER, at its prompt:

```sh
riscv32-alpine-linux-musl-gcc -v 2>&1 | tail -n 2
riscv32-alpine-linux-musl-gcc -print-multi-os-directory
riscv32-alpine-linux-musl-gcc -print-search-dirs | grep '^libraries'
ls /work/.local/share/abuild/main/riscv32/
```

- `-v`: the configure line must contain `--with-arch=rv32imac_zicsr_zifencei
  --with-abi=ilp32`.
- `-print-multi-os-directory` must print `.` or `../lib`, and the library
  search path must not contain `lib32/ilp32`: that is gcc patch 0024
  (multilib disabled) working for rv32 too.

## 5. Hello world under qemu-user

HOST (installing needs root in the container):

```sh
podman exec -u root alpine-rv32 apk add qemu-riscv32 file
```

Then CONTAINER:

```sh
cd /work
printf '#include <stdio.h>\nint main(void){puts("hello riscv32");return 0;}\n' > hello.c
riscv32-alpine-linux-musl-gcc -static -o hello-static hello.c
riscv32-alpine-linux-musl-gcc -o hello-dynamic hello.c
file hello-static hello-dynamic
qemu-riscv32 ./hello-static
qemu-riscv32 -L /work/sysroot-riscv32 ./hello-dynamic
```

- `file` must say `ELF 32-bit LSB ... UCB RISC-V, soft-float ABI`; the dynamic
  one names `/lib/ld-musl-riscv32.so.1` as its interpreter.
- `qemu-riscv32` runs a riscv32 Linux binary on x86_64 by translating its
  instructions and system calls. `-L` points it at the sysroot, where the
  dynamic binary's loader and libc live.

Done when: both print `hello riscv32`.
Next: step 9, the rest of the base system list.
