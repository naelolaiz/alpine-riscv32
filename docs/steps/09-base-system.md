# Step 9: the Alpine base system for riscv32

`bootstrap.sh riscv32` without a package list cross-builds Alpine's whole
bootstrap list: the libraries the compiler needs (zlib, gmp, mpfr, mpc, isl,
zstd), a native riscv32 binutils and gcc, the build tools (make, patch, file,
tar, fakeroot, abuild), and the base system (openssl, busybox, apk-tools,
openrc, alpine-baselayout, alpine-keys, alpine-conf, alpine-base). Packages
built in step 8 are skipped because they are up to date.

## 1. Sources from ftp.gnu.org

Four packages in the list download from `ftp.gnu.org`, which refused
connections in step 8. HOST, in the directory holding `aports`:

```sh
curl -fL -o .cache/distfiles/mpc-1.3.1.tar.gz https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz
curl -fL -o .cache/distfiles/make-4.4.1.tar.gz https://mirrors.kernel.org/gnu/make/make-4.4.1.tar.gz
curl -fL -o .cache/distfiles/patch-2.8.tar.xz https://mirrors.kernel.org/gnu/patch/patch-2.8.tar.xz
curl -fL -o .cache/distfiles/tar-1.35.tar.xz https://mirrors.kernel.org/gnu/tar/tar-1.35.tar.xz
```

attr, acl and lzip come from savannah, a different server; they are fetched
by abuild as usual.

## 2. Run it

CONTAINER, entered with `podman exec -it -u $(id -un) alpine-rv32 sh`, at its
prompt:

```sh
cd /work/aports
./scripts/bootstrap.sh riscv32 2>&1 | tee /work/bootstrap-step9.log
```

The native riscv32 gcc is the long part. This is the first time most of these
packages are built for riscv32, so a failure is a finding, not a mistake: the
last lines of the log name the package and the error, and it goes into
[`RISCV32.md`](../../RISCV32.md) with its class (Alpine, upstream package,
RV32, toolchain). After a fix, rerunning continues where it stopped.

## 3. Check

CONTAINER:

```sh
ls /work/.local/share/abuild/main/riscv32/ | wc -l
ls /work/.local/share/abuild/main/riscv32/ | grep -E '^(busybox|apk-tools|openrc|alpine-base)-'
```

Done when: the bootstrap ends without an error and busybox, apk-tools, openrc
and alpine-base are in the riscv32 repository.
Next: step 10, boot them in a full-system QEMU.
