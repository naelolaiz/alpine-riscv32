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
packages are built for riscv32, so a failure is a finding, not a mistake. It
goes into [`RISCV32.md`](../../RISCV32.md) with its class (Alpine, upstream
package, RV32, toolchain). After a fix, rerunning continues where it stopped,
because abuild skips packages that are already built.

The last lines of the log name the failing package but usually not the error,
because make runs several compile jobs at once and the others keep printing
after one fails. To find the compiler's error line, HOST, in the directory
holding `aports` (the spaces around `error:` match gcc's errors and skip make's
`Error 2` lines):

```sh
grep -n -B2 -A4 ' error: ' bootstrap-step9.log | head -n 30
```

## Fix 1: busybox, `SYS_settimeofday` undeclared

busybox 1.38.0 stops in `util-linux/hwclock.c:143`:

```
error: 'SYS_settimeofday' undeclared (first use in this function)
```

`set_kernel_tz()` calls the raw `settimeofday` syscall, because musl's
`settimeofday()` ignores the timezone argument. riscv32 is time64-only: its
kernel never had the old settimeofday syscall, so musl's riscv32 syscall list
has no `SYS_settimeofday` (riscv64 has it as 170). Without that syscall the
kernel timezone cannot be set at all on riscv32, so the fix makes that step a
no-op there. Buildroot carries a patch for the same error that returns failure
instead; that would make `hwclock -s` stop before it sets the clock.

The fix is a busybox patch in the package directory, because abuild deletes
`src/` and unpacks it fresh on every build. abuild leaves the failed build's
`src/` in place, which gives you the file to edit.

1. Save an untouched copy, because `diff` needs the original to compare
   against. HOST, in `aports/main/busybox/src`:

   ```sh
   cp busybox-1.38.0/util-linux/hwclock.c busybox-1.38.0/util-linux/hwclock.c.orig
   ```

2. Edit `busybox-1.38.0/util-linux/hwclock.c:143` so the syscall is only used
   where it exists (indent with a tab):

   ```diff
    #endif
   +#if defined(SYS_settimeofday)
    	int ret = syscall(SYS_settimeofday, NULL, tz);
   +#else
   +	/* riscv32 is time64-only and has no settimeofday syscall,
   +	 * so the kernel timezone cannot be set: nothing to do */
   +	int ret = 0;
   +#endif
    #else
    	int ret = settimeofday(NULL, tz);
   ```

3. Write the patch next to the APKBUILD. `--label` writes the `a/` and `b/`
   names that `patch -p1` expects and leaves out timestamps, so the file is the
   same on every machine. HOST, same directory:

   ```sh
   diff -u --label a/util-linux/hwclock.c --label b/util-linux/hwclock.c busybox-1.38.0/util-linux/hwclock.c.orig busybox-1.38.0/util-linux/hwclock.c > ../0043-hwclock-no-settimeofday-syscall-on-riscv32.patch
   sha512sum ../0043-hwclock-no-settimeofday-syscall-on-riscv32.patch
   ```

   The sum starts with `85878ab8`. If it does not, the edit differs; the usual
   cause is spaces instead of a tab.

4. Add it to `source=` in `aports/main/busybox/APKBUILD:90`, because abuild
   applies only the patches listed there, in that order:

   ```diff
    	0042-modprobe-Check-for-ELF-header-to-determine-if-module.patch
   +	0043-hwclock-no-settimeofday-syscall-on-riscv32.patch
    
    	acpid.logrotate
   ```

5. Add its checksum, because abuild refuses a source file with no matching
   `sha512sums` line. CONTAINER:

   ```sh
   cd /work/aports/main/busybox
   abuild checksum
   ```

6. Commit under the neutral identity. HOST, in the directory holding `aports`:

   ```sh
   git -C aports add main/busybox/APKBUILD main/busybox/0043-hwclock-no-settimeofday-syscall-on-riscv32.patch
   git -C aports commit -m "main/busybox: fix hwclock build on riscv32"
   ```

   This is [`patches/0006`](../../patches/0006-main-busybox-fix-hwclock-build-on-riscv32.patch).

7. Rerun the bootstrap; it resumes at busybox. CONTAINER:

   ```sh
   cd /work/aports
   ./scripts/bootstrap.sh riscv32 2>&1 | tee /work/bootstrap-step9b.log
   ```

## 3. Check

CONTAINER:

```sh
ls /work/.local/share/abuild/main/riscv32/ | wc -l
ls /work/.local/share/abuild/main/riscv32/ | grep -E '^(busybox|apk-tools|openrc|alpine-base)-'
```

Done when: the bootstrap ends without an error and busybox, apk-tools, openrc
and alpine-base are in the riscv32 repository.
Next: step 10, boot them in a full-system QEMU.
