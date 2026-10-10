# Step 11: native riscv32 builds

`scripts/bootstrap.sh` cross-builds a fixed list of packages. Every APKBUILD
in that list splits its build dependencies in two:

- `makedepends_build`: tools that run on the build machine.
- `makedepends_host`: libraries for the target.

abuild's cross mode installs the first list on x86_64 and the second into the
riscv32 sysroot. Most APKBUILDs have only a plain `makedepends`. For those,
cross mode installs all of it on the x86_64 side; the sysroot gets only
bootstrap.sh's fixed `EXTRADEPENDS_TARGET`. nano's `ncurses-dev`, for example,
would be missing exactly where the riscv32 compiler looks for it. The
`calcdeps()` function in `/usr/bin/abuild` shows both branches. CONTAINER
`alpine-rv32`:

```sh
grep -n -A35 '^calcdeps' /usr/bin/abuild
```

Alpine builds everything outside the bootstrap list natively, on a machine of
the target architecture. Here that machine is a riscv32 container: every
program in it is riscv32, and the host kernel runs each one through
binfmt_misc and `qemu-riscv32`, as in step 10. Every compiler process is
emulated, so builds are much slower than the cross builds of step 9.

## What this step builds

The plan lists dropbear, curl, ca-certificates, iproute2, e2fsprogs,
exfatprogs, strace, gdbserver and nano. ca-certificates is already built: it
is in bootstrap.sh's list (step 9). The others differ a lot in what they pull
in. The table counts source packages that are not built yet, computed from the
APKBUILDs' `makedepends`, `depends` and `depends_dev` with `BOOTSTRAP=1` (see
section 6). The counts are approximate: they include every runtime dependency
of every build dependency.

| Package | Not yet built | What makes it big |
| --- | --- | --- |
| nano | 2 | ncurses only |
| dropbear | 12 after nano | utmps (4 small skarnet packages); perl, m4, autoconf, automake for `autoreconf` |
| exfatprogs | 24 after the two above | util-linux (libblkid), whose libcap-ng needs python3 and swig |
| strace | 88 after the two above | elfutils, which needs curl and libarchive |
| gdb (for gdbserver) | 87 after the two above | the full gdb: python3, elfutils, texinfo |
| iproute2 | 91 after the two above | elfutils, iptables |
| curl | 71 after the two above | cmake (for brotli, c-ares), whose manual needs python3 and sphinx; meson for libpsl |
| e2fsprogs | 118 after the two above | util-linux, and fuse3 (for `fuse2fs`), which needs eudev, glib, gobject-introspection |

Together, the last six need about 145 more source packages, 40 of them
Python modules. Most of that weight is documentation and optional features.

This step builds nano and dropbear (14 source packages), because Phase 4 needs
an SSH server (step 17) and nano is the smallest real test of the
environment. The other six come later, after trimming what they pull in
(section 8). Section 8 also builds vim, htop, mc, python3 and neofetch;
fastfetch is parked.

## 1. Let setuid programs work through binfmt_misc

abuild installs build dependencies with `abuild-apk`, a setuid-root helper
that checks the `abuild` group. When the kernel runs a program through a
binfmt_misc interpreter, it normally takes the credentials from the
interpreter (`qemu-riscv32-static`, not setuid), so the setuid bit of a
riscv32 program is ignored. `abuild-apk` would then fail with
`setuid(0) failed: Operation not permitted`.

The `C` flag makes the kernel take the credentials from the riscv32 program
instead. It implies `O`: the kernel opens the program itself and hands qemu a
file descriptor. Only root can make a file setuid root, so this gives no one
new rights on the host.

HOST, in the directory holding `aports`. Look at the current rule first; it
does not exist after a reboot:

```sh
cat /proc/sys/fs/binfmt_misc/qemu-riscv32
```

Remove it, then register it again with the flags `OCFP`. The `echo -1` line
prints `No such file or directory` if the rule was already gone, which is
harmless. The second `sed` expression replaces the last field of the rule (its
flags) because that is where the flags live (`:name:type:offset:magic:mask:interpreter:flags`).

```sh
echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-riscv32
sed -e "s|/usr/bin/qemu-riscv32|$PWD/qemu-riscv32-static|" -e 's|:[A-Z]*$|:OCFP|' qemu-riscv32.conf | sudo tee /proc/sys/fs/binfmt_misc/register
cat /proc/sys/fs/binfmt_misc/qemu-riscv32
```

The last command prints `enabled`, the interpreter path and `flags: POCF`.

## 2. The riscv32 build tree

CONTAINER `alpine-rv32` as root (`podman exec -it -u root alpine-rv32 sh`).
The key goes in first because apk only installs packages signed by a key in
the new tree's `/etc/apk/keys`. The package list is the minimum to build with:

- `alpine-baselayout`: `/etc/passwd`, `/etc/group` and the directory layout.
- `busybox` and `busybox-binsh`: the shell and core utilities; `busybox-binsh`
  is the package that provides `/bin/sh`.
- `apk-tools`: abuild installs and removes build dependencies with it.
- `abuild`: pulls in fakeroot, tar, scanelf, openssl and the other tools it
  calls. `abuild-sudo` (the `abuild-apk` helper) comes with it through
  `install_if`. Its install script creates the `abuild` group.
- `build-base`: gcc, g++, binutils, make, musl-dev, the native riscv32
  compiler from step 9.

```sh
mkdir -p /var/tmp/rv32-native/etc/apk/keys
cp /work/.config/abuild/*.rsa.pub /var/tmp/rv32-native/etc/apk/keys/
apk add --root /var/tmp/rv32-native --initdb --arch riscv32 --repository /work/.local/share/abuild/main alpine-baselayout busybox busybox-binsh apk-tools abuild build-base
echo /work/.local/share/abuild/main > /var/tmp/rv32-native/etc/apk/repositories
chroot /var/tmp/rv32-native gcc -dumpmachine
```

- `--repository` on the command line is used for this install only, so the
  `echo` line writes it into the tree for later `apk` and `abuild` calls.
  `/work` will be mounted at the same place in the new container.
- The `busybox` device-node warning from step 10 shows up again; it is
  harmless for the same reason.
- `gcc -dumpmachine` prints `riscv32-alpine-linux-musl`.

## 3. Turn the tree into a container

HOST, in the directory holding `aports`. Do not add `-t` or `-it` to the first
`podman exec`: a terminal would mangle the binary tar stream.

```sh
podman exec -u root alpine-rv32 tar -C /var/tmp/rv32-native -cf - . | podman import - localhost/rv32-native
podman run -d --name rv32-native --userns=keep-id -v "$PWD":/work:z -w /work localhost/rv32-native sleep infinity
podman exec -u root rv32-native addgroup $(id -un) abuild
```

- `tar` runs inside `alpine-rv32`, where the tree is, as root, so owners and
  the setuid bit are kept. It writes to the pipe (`-f -`), and `podman import`
  reads the pipe (`-`) and stores the tree as an image named
  `localhost/rv32-native`.
- The image metadata says amd64, because `import` records the host's
  architecture. That does not matter: the kernel picks qemu from each
  program's ELF header, not from the image.
- The `run` options are those of step 7 for the same reasons (keep-id, the
  shared directory, `sleep infinity`). `HOME` is `/work` again, so abuild
  finds the same signing key and settings and writes packages to the same
  repository.
- `:z` (lowercase) instead of `:Z`, because two containers now share the
  directory. On an SELinux system `:Z` would claim it for one container
  only; without SELinux both are ignored.
- `addgroup` puts your user in the `abuild` group, which `abuild-apk` checks.

Both containers write the same repository index. Run one build at a time,
in either container.

## 4. Check

HOST:

```sh
podman exec -it -u $(id -un) rv32-native sh
```

CONTAINER `rv32-native`, at its prompt:

```sh
uname -m
apk --print-arch
id
abuild-apk --version
gcc -dumpmachine
```

- `uname -m` and `apk --print-arch` print `riscv32`.
- `id` lists `300(abuild)`.
- `abuild-apk --version` prints `apk-tools 3.0.8-r0, compiled for riscv32.`
  It goes through the setuid helper. `setuid(0) failed` means the binfmt rule
  lacks `C` (section 1).
- `gcc -dumpmachine` prints `riscv32-alpine-linux-musl`. abuild takes the
  build architecture from `apk --print-arch`, so build and host are the same
  and every `./configure` runs in native mode.

## 5. First native build: ncurses and nano

Download in `alpine-rv32`, the x86_64 container. Downloading does not depend
on the architecture, x86_64 does it without emulation, and the files land in
the shared `.cache/distfiles` (`SRCDEST`), where the riscv32 abuild finds
them and only checks their sha512.

CONTAINER `alpine-rv32`, as your user (`podman exec -it -u $(id -un) alpine-rv32 sh`):

```sh
cd /work/aports/main/ncurses
abuild fetch verify
cd /work/aports/main/nano
abuild fetch verify
```

CONTAINER `rv32-native`, as your user. ncurses first, because nano's
`makedepends` has `ncurses-dev`:

```sh
cd /work/aports/main/ncurses
abuild -r
cd /work/aports/main/nano
abuild -r
```

`-r` installs the build dependencies through `abuild-apk` and removes them
again when the package is done. Check, same container:

```sh
ls /work/.local/share/abuild/main/riscv32/ | grep -E '^(ncurses|nano)'
abuild-apk add nano
nano --version
abuild-apk del nano
```

`nano --version` prints `GNU nano, version 9.2`. Removing it keeps the build
container at its minimal set.

## 6. dropbear and the tools it needs

dropbear's `prepare()` runs `autoreconf -fvi` to regenerate its `configure`
after Alpine's patches, so it needs autoconf and automake, and those are perl
and m4 programs. The order follows the dependencies:

| Package | Why it is here |
| --- | --- |
| skalibs | C library under all skarnet.org tools |
| execline | scripting language s6 is built on |
| s6 | supervision suite; utmps runs its daemons with `s6-ipcserver` |
| utmps | utmp and wtmp for musl; dropbear's APKBUILD links it (`utmps-dev utmps-static`) |
| bzip2 | in perl's `makedepends_host` |
| tzdata | in perl's `makedepends_host` |
| perl | autoconf, automake and texinfo are perl programs |
| texinfo | in m4's `makedepends`, for m4's info manual |
| m4 | autoconf's macros run through m4 |
| autoconf, automake | `autoreconf` |
| dropbear | the SSH server |

Check the dropbear claim yourself, CONTAINER (either one):

```sh
grep -n -A3 '^prepare' /work/aports/main/dropbear/APKBUILD
```

### Sources

m4, autoconf and automake download from `ftp.gnu.org`, which refused
connections in step 8, and texinfo from GNU's mirror redirector. HOST, in the directory holding
`aports`, from the official mirror as in steps 8 and 9:

```sh
curl -fL --connect-timeout 20 -o .cache/distfiles/m4-1.4.21.tar.gz https://mirrors.kernel.org/gnu/m4/m4-1.4.21.tar.gz
curl -fL --connect-timeout 20 -o .cache/distfiles/autoconf-2.73.tar.gz https://mirrors.kernel.org/gnu/autoconf/autoconf-2.73.tar.gz
curl -fL --connect-timeout 20 -o .cache/distfiles/automake-1.18.1.tar.xz https://mirrors.kernel.org/gnu/automake/automake-1.18.1.tar.xz
curl -fL --connect-timeout 20 -o .cache/distfiles/texinfo-7.3.tar.xz https://mirrors.kernel.org/gnu/texinfo/texinfo-7.3.tar.xz
```

The rest, and the checksums of all twelve: CONTAINER `alpine-rv32`, as your
user. The `( )` runs each `cd` in a subshell, so the loop always returns to
`main`; `|| break` stops at the first failure so it stays on screen.

```sh
cd /work/aports/main
for p in skalibs execline s6 utmps bzip2 tzdata perl texinfo m4 autoconf automake dropbear; do (cd $p && abuild fetch verify) || break; done
```

### Build

CONTAINER `rv32-native`, as your user. `ABUILD_BOOTSTRAP=1` makes abuild's
`want_check()` return false, so it skips `check()` and does not install
`checkdepends`. Two reasons:

- m4's `checkdepends` is diffutils, which is not built.
- perl's test suite is large, and every test would run under emulation.

The packages are the same; only the tests are skipped. The variable lives in
this shell only, so the x86_64 container's cross builds are not affected.

```sh
export ABUILD_BOOTSTRAP=1
cd /work/aports/main
for p in skalibs execline s6 utmps bzip2 tzdata perl texinfo m4 autoconf automake dropbear; do (cd $p && abuild -r) || break; done
```

The loop is the table above in order. To go one package at a time instead,
`cd skalibs && abuild -r`, and so on. After a failure and a fix, the same loop
resumes: abuild skips packages that are already up to date.

## 7. Check: SSH into the QEMU machine

The step 10 VM can run dropbear. QEMU's user-mode network ("slirp") gives the
VM a NAT connection and an address by DHCP. `hostfwd` forwards port 2222
inside `alpine-rv32` to port 22 in the VM.

HOST, an SSH client for `alpine-rv32`, because the Alpine image does not ship
one:

```sh
podman exec -u root alpine-rv32 apk add openssh-client
```

CONTAINER `alpine-rv32`, as your user, the step 10 boot plus a network card:

- `-netdev user,...` is the host side: the user-mode network, with the
  port forward.
- `-device virtio-net-pci,netdev=net0` is the card in the VM, plugged into the
  `virt` board's PCI bus and connected to that network by its `id`.
- The shorter `-nic user,model=virtio-net-pci` does nothing on this board.
  `-nic` only asks the board to create its default card, and QEMU's
  `hw/riscv/virt.c` never does (`hw/arm/virt.c` calls `pci_init_nic_devices()`).
  QEMU only warns `requested NIC ... was not created (not supported by this
  machine?)` and boots without a card.

```sh
qemu-system-riscv32 -M virt -m 256M -nographic \
	-kernel /work/linux-6.18/arch/riscv/boot/Image \
	-append "root=/dev/vda rw console=ttyS0" \
	-drive file=/work/qemu/alpine-rv32.img,format=raw,if=virtio \
	-virtfs local,path=/work/.local/share/abuild,mount_tag=repo,security_model=none,readonly=on \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
	-device virtio-net-pci,netdev=net0
```

In the VM, as root:

- dropbear's OpenRC service `need`s `net`, which the `networking` service
  provides from `/etc/network/interfaces`. The file does not exist yet.
- dropbear refuses logins with an empty password, so root needs one. This
  password is for the VM only.
- The first start generates the host keys, which takes a while under
  emulation.

```sh
mount -t 9p -o trans=virtio,version=9p2000.L repo /mnt
apk add --repository /mnt/main dropbear nano
printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n' > /etc/network/interfaces
rc-service networking start
passwd
rc-service dropbear start
```

`rc-service networking start` shows `eth0` getting `10.0.2.15`.

A second terminal. HOST:

```sh
podman exec -it -u $(id -un) alpine-rv32 sh
```

CONTAINER `alpine-rv32`, at its prompt:

```sh
ssh -p 2222 root@127.0.0.1 uname -m
```

ssh asks to accept the host key, then the password, and prints `riscv32`.

## 8. Later: the rest of the list

The other six are not needed to boot Alpine on the board:

- apk fetches over HTTP with its own code, so step 15 can test with
  `apk add nano` instead of curl.
- Without e2fsprogs there is no `fsck.ext4`, so the pendrive root gets
  `0` in the `fstab` pass field until it exists. The subsection below
  builds it on the way to mc.

Before building them, the APKBUILDs can drop what is only documentation or an
optional feature when `BOOTSTRAP` or `APORTS_BOOTSTRAP` is set, as the edits
below do for vim, htop, glib and e2fsprogs. Other candidates: cmake's sphinx
manual, elfutils' debuginfod (which needs curl), and gdbserver built on its
own instead of the full gdb. Each such change is one generic patch in
`patches/`.

### vim, htop, mc, python3 and neofetch

These five build with four edits, patches 0007 to 0010, and two fixes,
patches 0011 and 0012. Counted as in the
table at the top, on top of what sections 5 and 6 built:

| Package | Not yet built, as is | With the edits | What the edits drop |
| --- | --- | --- | --- |
| python3 | 14 | 14 | nothing, no edit needed |
| htop | 136 | 8 | temperature readings through lm-sensors, whose package pulls in rrdtool, cairo and pango (0008) |
| vim | 272 | 1 | gvim (gtk+3.0, X11) and the Lua, Perl, Python, Ruby and Tcl script interfaces; ruby alone pulls in rust and llvm (0007) |
| neofetch | 1 after bash | 1 after bash | nothing: it is a bash script in `testing/` |
| mc | 123 | 26 after the above | `fuse2fs` in e2fsprogs, whose fuse3 pulls in eudev, glib's introspection chain and cairo (0010); glib's man pages and DocBook tools (0009) |

All five together are 47 source packages. mc keeps its ext2 attribute
support, so e2fsprogs gets built along the way, `fsck.ext4` included.
fastfetch stays parked: about 15 packages (cmake without its sphinx manual,
yyjson).

All four edits only apply when `BOOTSTRAP` or `APORTS_BOOTSTRAP` is set, the
convention util-linux, curl and openssh already use. Without those variables
the APKBUILDs build exactly what they build today, so the edits are generic
and can go upstream.

#### Apply the patches

HOST, in the directory holding `aports` and `alpine-riscv32`. `git am`
applies each patch and commits it with its author and message, so `aports`
gets one commit per package, as in aports. `$PWD` is needed because `-C
aports` makes git resolve paths from inside `aports`:

```sh
git -C aports am "$PWD"/alpine-riscv32/patches/000[789]-*.patch "$PWD"/alpine-riscv32/patches/001[012]-*.patch
git -C aports log --oneline -5
```

The log shows the six commits on top of the busybox one (0006). If `am`
stops at 0007 or 0008 because those edits are already in the tree,
`git -C aports am --abort` and apply only 0009 to 0012.

0011 and 0012 came later. If 0007 to 0010 are already applied, apply only
the ones `git -C aports log --oneline -6` does not list yet, from the same
directory, for example:

```sh
git -C aports am "$PWD"/alpine-riscv32/patches/0012-*.patch
```

The six subsections below show what each patch changes and why.

#### Edit 1: vim (patch 0007)

`aports/community/vim/APKBUILD:15`, the dependency list:

```diff
-makedepends="
-	lua$_luaver-dev
-	ncurses-dev
-	perl-dev
-	python3-dev
-	ruby-dev
-	tcl-dev
-	"
+makedepends="ncurses-dev"
+if [ -z "$BOOTSTRAP" ] && [ -z "$APORTS_BOOTSTRAP" ]; then
+	# script interfaces, loaded at run time; ruby alone pulls in rust and llvm
+	makedepends="$makedepends lua$_luaver-dev perl-dev python3-dev ruby-dev tcl-dev"
+	_interp_config="--enable-luainterp=dynamic --enable-perlinterp=dynamic
+		--enable-python3interp=dynamic --enable-rubyinterp=dynamic
+		--enable-tclinterp=dynamic"
+else
+	# gvim pulls in gtk+3.0 and X11
+	: "${BUILD_GVIM:=false}"
+fi
```

`aports/community/vim/APKBUILD:304` (line 307 after the first hunk), in `_build()`:

```diff
 		--prefix=/usr \
-		--enable-luainterp=dynamic \
-		--enable-perlinterp=dynamic \
-		--enable-python3interp=dynamic \
-		--enable-rubyinterp=dynamic \
-		--enable-tclinterp=dynamic \
+		$_interp_config \
 		--disable-nls \
```

- `BUILD_GVIM` is the APKBUILD's own switch (`: "${BUILD_GVIM:=true}"` a few
  lines further down). `:=` only assigns when the variable is unset, so the
  `false` set first wins.
- `$_interp_config` is unquoted on purpose: empty, it adds no argument; set,
  it splits into the five flags. Without them, vim's `configure` leaves the
  interfaces off.

#### Edit 2: htop (patch 0008)

`aports/main/htop/APKBUILD:16`:

```diff
-makedepends="ncurses-dev linux-headers lm-sensors-dev"
+makedepends="ncurses-dev linux-headers"
+if [ -z "$BOOTSTRAP" ] && [ -z "$APORTS_BOOTSTRAP" ]; then
+	# lm-sensors pulls in rrdtool, cairo and pango
+	makedepends="$makedepends lm-sensors-dev"
+fi
```

htop's `configure.ac` defaults `--enable-sensors` to `check`: without
`sensors/sensors.h` it turns the feature off instead of failing. htop loads
libsensors with `dlopen` at run time and only needs the header to build.

#### Edit 3: glib (patch 0009)

mc needs glib. `aports/main/glib/APKBUILD:13` to `:107`, three hunks:

```diff
@@ -13,14 +13,20 @@ license="LGPL-2.1-or-later"
 triggers="$pkgname.trigger=/usr/share/glib-2.0/schemas:/usr/lib/gio/modules:/usr/lib/gtk-4.0"
 depends_dev="
 	bzip2-dev
-	docbook-xml
-	docbook-xsl
 	gettext-dev
-	libxml2-utils
-	libxslt
 	python3
 	py3-packaging
 	"
+subpackages="$pkgname-dbg"
+_man_pages=disabled
+if [ -z "$BOOTSTRAP" ] && [ -z "$APORTS_BOOTSTRAP" ]; then
+	# man pages (rst2man) and the DocBook tools; these pull in libxml2,
+	# libxslt, libgcrypt and py3-docutils
+	depends_dev="$depends_dev docbook-xml docbook-xsl libxml2-utils libxslt"
+	_docdepends="py3-docutils"
+	subpackages="$subpackages $pkgname-doc"
+	_man_pages=enabled
+fi
 makedepends="$depends_dev
 	bash
 	bison
@@ -32,11 +38,9 @@ makedepends="$depends_dev
 	python3-dev
 	util-linux-dev
 	zlib-dev
-	py3-docutils
+	$_docdepends
 	"
-subpackages="
-	$pkgname-dbg
-	$pkgname-doc
+subpackages="$subpackages
 	$pkgname-static
 	$pkgname-dev
 	$pkgname-lang
@@ -101,7 +105,7 @@ build() {
 		--reconfigure \
 		--pkg-config-path="$_prefix"/lib/pkgconfig \
 		--default-library=both \
-		-Dman-pages=enabled \
+		-Dman-pages=$_man_pages \
 		-Dlibmount=enabled \
 		-Dtests="$(want_check && echo true || echo false)" \
 		-Dintrospection=enabled \
```

- glib 2.90 builds its man pages with `rst2man` (py3-docutils) only; see
  `find_program('rst2man' ...)` in glib's top `meson.build`. The DocBook
  tools in `depends_dev` are not used by glib's own build, so they stay for
  `glib-dev` users when not bootstrapping. Together they pull in libxslt,
  libgcrypt, libgpg-error and the docutils chain.
- Without man pages `glib-doc` would be empty, and abuild stops with
  `Missing subpkgdir for glib-doc` on an empty subpackage
  (`prepare_package()` in `/usr/bin/abuild`), so the subpackage goes too.
- `subpackages` is built in pieces so `glib-doc` keeps its place after
  `glib-dbg` in a normal build; the split functions run in that order.

#### Edit 4: e2fsprogs (patch 0010)

mc reads ext2 file attributes through e2fsprogs' libe2p. `aports/main/e2fsprogs/APKBUILD:11`:

```diff
@@ -8,14 +8,20 @@ url="https://e2fsprogs.sourceforge.net/"
 arch="all"
 license="GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT"
 depends_dev="util-linux-dev gawk"
-makedepends="$depends_dev linux-headers fuse3-dev"
+makedepends="$depends_dev linux-headers"
 checkdepends="diffutils perl coreutils"
 subpackages="
 	$pkgname-static
 	$pkgname-dev
 	libcom_err
-	fuse2fs
-	fuse2fs-doc:fuse2fs_doc:noarch
+	"
+if [ -z "$BOOTSTRAP" ] && [ -z "$APORTS_BOOTSTRAP" ]; then
+	# fuse3 pulls in eudev, glib and gobject-introspection;
+	# configure builds fuse2fs only when it finds fuse
+	makedepends="$makedepends fuse3-dev"
+	subpackages="$subpackages fuse2fs fuse2fs-doc:fuse2fs_doc:noarch"
+fi
+subpackages="$subpackages
 	$pkgname-doc
 	$pkgname-libs
 	$pkgname-extra
```

e2fsprogs' `configure.ac` (`AC_ARG_ENABLE([fuse2fs]`) looks for fuse when
`--disable-fuse2fs` is not given and quietly skips fuse2fs when it finds
none. The `fuse2fs` split function would then fail on the missing
`usr/bin/fuse2fs`, so the two fuse2fs subpackages go with the dependency.

#### Fix 5: util-linux keeps utmps (patch 0011)

util-linux's own bootstrap gate dropped `utmps-dev` and the utmps compiler
flags, and the build then stopped in `login-utils/last.c` with `'_PATH_WTMP'
undeclared`. Alpine's musl removes `_PATH_UTMP` and `_PATH_WTMP` from
`<paths.h>` (`main/musl/adjust-paths.patch`) because utmps' `<utmpx.h>` and
util-linux's `utmps.patch` provide them, so util-linux needs utmps even
when bootstrapping. utmps and its chain (skalibs, execline, s6) were built in
section 6 for dropbear, so this adds no package. `aports/main/util-linux/APKBUILD:17`:

```diff
@@ -17,6 +17,8 @@ makedepends_host="
 	linux-headers
 	ncurses-dev
 	sqlite-dev
+	utmps-dev
+	utmps-static
 	zlib-dev
 	"
 subpackages="
@@ -59,8 +61,6 @@ if [ -z "$BOOTSTRAP" ] && [ -z "$APORTS_BOOTSTRAP" ]; then
 		linux-pam-dev
 		python3-dev
 		libeconf-dev
-		utmps-dev
-		utmps-static
 		"
 	subpackages="$subpackages
 		$pkgname-login
@@ -148,14 +148,18 @@ prepare() {
 }
 
 build() {
+	# Linking utmps statically is strongly preferred by the utmps author
+	# and also much more space efficient - adds 4 kiB to each binary, that's
+	# 20 kiB in total for util-linux-*, versus 196 kiB (libskarnet.so).
+	# TODO: Find a better way (libutmps.so w/o dependency on libskarnet.so)?
+	# musl's <paths.h> on Alpine has no _PATH_UTMP and _PATH_WTMP, utmps
+	# provides them, so it is needed when bootstrapping too.
+	export CFLAGS="$CFLAGS $(pkg-config --cflags --static libutmps)"
+	export LDFLAGS="$LDFLAGS $(pkg-config --libs --static libutmps)"
 	if [ -z "$BOOTSTRAP" ]; then
-		# Linking utmps statically is strongly preferred by the utmps author
-		# and also much more space efficient - adds 4 kiB to each binary, that's
-		# 20 kiB in total for util-linux-*, versus 196 kiB (libskarnet.so).
-		# TODO: Find a better way (libutmps.so w/o dependency on libskarnet.so)?
 		# also throw in lto when not bootstrapping
-		export CFLAGS="$CFLAGS -ffat-lto-objects -flto=auto $(pkg-config --cflags --static libutmps)"
-		export LDFLAGS="$LDFLAGS $(pkg-config --libs --static libutmps) $(pkg-config --libs libeconf)"
+		export CFLAGS="$CFLAGS -ffat-lto-objects -flto=auto"
+		export LDFLAGS="$LDFLAGS $(pkg-config --libs libeconf)"
 	fi
 
 	# --disable-chfn-chsh - chfn and chsh are provided by shadow package
```

`pkg-config --cflags libutmps` adds `-I/usr/include/utmps`, so `<utmpx.h>`
is utmps' header, and `utmps.patch` then defines `_PATH_WTMP`. Without the
variables the full build gets the same flags as before, in another order.

#### Fix 6: pcre2 without JIT on riscv32 (patch 0012)

On the board, mc died with `Illegal instruction`. The kernel log
(`dmesg`) showed the trap in anonymous memory, on a valid compressed
instruction (`7139`, `addi sp,sp,-64`) right after the block header of
pcre2's JIT allocator: code that pcre2 generates at run time for a regular
expression, which mc uses through glib. `pcre2grep` shows it directly:

```sh
echo hello | pcre2grep 'h.l+o'
echo hello | pcre2grep --no-jit 'h.l+o'
```

The first dies with `Illegal instruction`, the second prints `hello`. The
likely cause is that the instruction cache does not see the freshly written
code on the ESP32-S31 (musl does ask the kernel to synchronise it, through
the `riscv_flush_icache` system call), which userspace cannot fix. pcre2
then builds without JIT on riscv32, as it already does on sh; glib falls
back to pcre2's interpreter on its own. `pkgrel` goes up so that apk
replaces copies built before. `aports/main/pcre2/APKBUILD:5` and `:44`:

```diff
@@ -2,7 +2,7 @@
 # Maintainer: Jakub Jirutka <jakub@jirutka.cz>
 pkgname=pcre2
 pkgver=10.49
-pkgrel=0
+pkgrel=1
 pkgdesc="Perl-compatible regular expression library"
 url="https://pcre.org/"
 arch="all"
@@ -42,7 +42,9 @@ source="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$pkgver/pc
 #     - CVE-2022-1587
 
 case "$CARCH" in
-	sh*) _enable_jit="";;
+	# riscv32: JIT code dies with SIGILL on its first instruction on the
+	# ESP32-S31 (rv32imac); the interpreter works
+	sh*|riscv32) _enable_jit="";;
 	*) _enable_jit="--enable-jit";;
 esac
 
```

#### Check

CONTAINER (either one). Each line prints `makedepends` and the subpackages;
with the variable set, vim lists only `ncurses-dev` and no `gvim`, htop has no
`lm-sensors-dev`, glib has no docbook, libxslt or py3-docutils and no
`glib-doc`, e2fsprogs has no `fuse3-dev` and no `fuse2fs`, util-linux lists
`utmps-dev utmps-static`:

```sh
cd /work/aports/community/vim && APORTS_BOOTSTRAP=1 sh -c '. ./APKBUILD; echo $makedepends; echo $subpackages'
cd /work/aports/main/htop && APORTS_BOOTSTRAP=1 sh -c '. ./APKBUILD; echo $makedepends'
cd /work/aports/main/glib && APORTS_BOOTSTRAP=1 sh -c '. ./APKBUILD; echo $makedepends; echo $subpackages'
cd /work/aports/main/e2fsprogs && APORTS_BOOTSTRAP=1 sh -c '. ./APKBUILD; echo $makedepends; echo $subpackages'
cd /work/aports/main/util-linux && APORTS_BOOTSTRAP=1 sh -c '. ./APKBUILD; echo $makedepends'
```

Run the same five lines without `APORTS_BOOTSTRAP=1` to see the full lists
come back.

#### Sources

Several of these download from `ftp.gnu.org` (readline and bash with their
patch files, diffutils, help2man, libtool, bison, gawk, libunistring,
gettext), and gpm's home page is gone. Instead of one curl per file, let
abuild try Alpine's distfiles first. When `DISTFILES_MIRROR` is set, abuild's
`uri_fetch_mirror()` asks for `$DISTFILES_MIRROR/<file name>` and only falls
back to the original URL if that fails. Alpine's server keeps exactly the
files its builders checksummed (as with fakeroot in step 9), which also
avoids the regenerated GitHub and Codeberg archive tarballs. HOST, same
directory; both containers read this file, because `HOME` is `/work` in both.
`grep -q` succeeds when the line is already there, so `||` only appends it
once:

```sh
grep -q '^DISTFILES_MIRROR=' .config/abuild/abuild.conf || echo 'DISTFILES_MIRROR=https://distfiles.alpinelinux.org/distfiles/edge' >> .config/abuild/abuild.conf
```

CONTAINER `alpine-rv32`, as your user. The list is the build order below, all
three groups in one go:

```sh
cd /work/aports
for p in main/expat main/bluez-headers main/libffi main/mpdecimal main/chrpath main/readline main/sqlite main/tcl main/diffutils main/help2man main/libtool main/gettext-tiny main/xz main/python3 main/bison main/flex main/bash main/lsof main/htop community/vim testing/neofetch main/libedit main/pcre2 main/swig main/libcap-ng main/util-linux main/gawk main/e2fsprogs main/libxml2 main/libunistring main/gettext main/py3-installer main/py3-flit-core main/py3-gpep517 main/py3-parsing main/py3-packaging main/samurai main/py3-setuptools main/py3-wheel main/meson main/glib main/libssh2 main/libpng main/oniguruma main/slang main/gpm main/mc; do (cd $p && abuild fetch verify) || break; done
```

#### Build

First, OpenSSL again, natively. Its APKBUILD adds `no-threads` whenever
`CBUILD` and `CHOST` differ (its comment: libatomic is not available when
cross building), so the libcrypto3 and libssl3 from step 9 have no thread
support, and python3's `_ssl` and `_hashopenssl` stop with `OPENSSL_THREADS
is not defined, Python requires thread-safe OpenSSL`. Alpine's own
bootstrap rebuilds openssl natively for the same reason. CONTAINER
`rv32-native`, as your user:

```sh
export ABUILD_BOOTSTRAP=1 APORTS_BOOTSTRAP=1
cd /work/aports/main/openssl && abuild -rf
abuild-apk add /work/.local/share/abuild/main/riscv32/libcrypto3-3.5.9-r0.apk /work/.local/share/abuild/main/riscv32/libssl3-3.5.9-r0.apk
abuild-apk del libcrypto3 libssl3
tar -xzOf /work/.local/share/abuild/main/riscv32/openssl-dev-3.5.9-r*.apk usr/include/openssl/configuration.h 2>/dev/null | grep THREADS
```

- `-f` forces the build: the package from step 9 has the same version, so
  abuild would otherwise call it up to date.
- The new packages have the same version as the cross-built ones, so
  neither `apk upgrade` nor `apk fix` takes them: `fix` reinstalls exactly
  the installed package, identified by its checksum, and prints `[APK
  unavailable, skipped]` when the repository only has the new build. Adding
  the two files makes apk see a different package of the same version, and
  it replaces the installed one (`Replacing`).
- Adding a file also writes its checksum into `/etc/apk/world`, which would
  pin the library. `abuild-apk del` removes those two entries again; the
  libraries stay installed because other packages depend on them.
- The board needs the same two commands with `apk` once it gets the new
  packages, with the path of its copy of the repository and
  `--repositories-file /dev/null` when the PC is not reachable.
- The last line prints `OPENSSL_THREADS` and no `OPENSSL_NO_THREADS`.

Then the three groups. `APORTS_BOOTSTRAP=1` switches on the
four edits, and the gate util-linux already has (no PAM, Python bindings or
`login`; utmps stays, patch 0011); `ABUILD_BOOTSTRAP=1` skips the tests as in section 6. Three groups,
so each target is usable as soon as its group is done:

```sh
export ABUILD_BOOTSTRAP=1 APORTS_BOOTSTRAP=1
cd /work/aports
for p in main/expat main/bluez-headers main/libffi main/mpdecimal main/chrpath main/readline main/sqlite main/tcl main/diffutils main/help2man main/libtool main/gettext-tiny main/xz main/python3; do (cd $p && abuild -r) || break; done
for p in main/bison main/flex main/bash main/lsof main/htop community/vim testing/neofetch; do (cd $p && abuild -r) || break; done
for p in main/libedit main/pcre2 main/swig main/libcap-ng main/util-linux main/gawk main/e2fsprogs main/libxml2 main/libunistring main/gettext main/py3-installer main/py3-flit-core main/py3-gpep517 main/py3-parsing main/py3-packaging main/samurai main/py3-setuptools main/py3-wheel main/meson main/glib main/libssh2 main/libpng main/oniguruma main/slang main/gpm main/mc; do (cd $p && abuild -r) || break; done
```

- Group 1 is python3 and its libraries. libtool and xz come before python3
  because xz runs `autoreconf` with libtool; diffutils and help2man are
  libtool's `depends` and `makedepends`.
- python3 is the longest single build: `--enable-optimizations` builds the
  interpreter, runs part of its test suite to collect a profile, and builds
  it again with that profile, all under emulation. Failing tests in the
  profile run do not stop the build (`|| true` in Python's `Makefile`).
- Group 2: bison and flex before bash (its `makedepends`), bash before lsof,
  lsof before htop (`abuild -r` also installs `depends`), bash before
  neofetch.
- Group 3 is mc's chain: util-linux (libmount for glib, libuuid and libblkid
  for e2fsprogs) needs libcap-ng, whose Python bindings need swig, and
  utmps from section 6; glib
  builds with meson, a python3 program, which needs the `py3-` build tools
  first.
- abuild takes the repository name from the APKBUILD's parent directory, so
  vim lands in `community/riscv32` and neofetch in `testing/riscv32` next to
  `main/riscv32`. neofetch is `noarch`; abuild still files it under the
  build architecture.
- If you built group 3 before patch 0012, rebuild pcre2 alone: `cd
  /work/aports/main/pcre2 && abuild -r`. The new `pkgrel` makes abuild see
  it as out of date, and the board takes `pcre2-10.49-r1` with `apk
  upgrade`. Nothing else needs a rebuild: glib and mc call pcre2 through
  its shared library.

### Small tools and Wi-Fi

Built after the five above, these need 30 source packages and one edit,
patch 0013 for wpa_supplicant:

- everyday: tmux, less, tree, ncdu, btop, rsync
- board and hardware: dtc, i2c-tools, evtest, memtester, dosfstools,
  exfatprogs
- Wi-Fi and network: wpa_supplicant, iw, wireless-regdb, iperf3, ethtool,
  socat
- lua5.4

The other 11 are their libraries and build tools: libevent (tmux),
coreutils, bmake and lowdown (btop's build and man page), libidn2, lz4,
popt and xxhash (rsync), musl-fts (exfatprogs), libnl3 (iw,
wpa_supplicant), libmnl (ethtool).

#### Edit 7: wpa_supplicant (patch 0013)

As is, wpa_supplicant needs about 86 source packages: dbus (about 20) for
its D-Bus control interface and pcsc-lite (about 80, through eudev and gobject-introspection) for
SIM cards. Native Wi-Fi only needs `wpa_cli` and the control socket, so the
patch leaves both out when bootstrapping. `aports/main/wpa_supplicant/APKBUILD:12`
and `:65`:

```diff
@@ -9,7 +9,12 @@ arch="all"
 options="!check" # has no tests
 license="BSD-3-Clause"
 subpackages="$pkgname-doc $pkgname-openrc $pkgname-systemd"
-makedepends="linux-headers openssl-dev>3 dbus-dev libnl3-dev pcsc-lite-dev"
+makedepends="linux-headers openssl-dev>3 libnl3-dev"
+if [ -z "$BOOTSTRAP" ] && [ -z "$APORTS_BOOTSTRAP" ]; then
+	# D-Bus control interface and PC/SC smartcards (EAP-SIM/AKA with a
+	# SIM card); dbus and pcsc-lite pull in about 85 source packages
+	makedepends="$makedepends dbus-dev pcsc-lite-dev"
+fi
 provides="nm-wifi-backend"
 provider_priority=10 # highest
 source="https://w1.fi/releases/wpa_supplicant-$pkgver.tar.gz
@@ -63,6 +68,10 @@ prepare() {
 
 	# Copy our configuration file to the build directory
 	cp "$srcdir"/config "$builddir"/wpa_supplicant/.config
+	if [ -n "$BOOTSTRAP" ] || [ -n "$APORTS_BOOTSTRAP" ]; then
+		sed -i -e '/^CONFIG_CTRL_IFACE_DBUS/d' -e '/^CONFIG_PCSC=/d' \
+			"$builddir"/wpa_supplicant/.config
+	fi
 }
 
 build() {
```

- The `makedepends` hunk drops the two libraries; the `prepare()` hunk
  deletes the three options that need them from the build's `.config`, a
  copy of the `config` file next to the APKBUILD.
- EAP-SIM and EAP-AKA stay enabled: `src/utils/pcsc_funcs.h` has no-op
  stubs when `PCSC_FUNCS` is not defined, so they only lose access to a
  physical SIM card.
- The OpenRC service only adds `-u` (D-Bus) when asked to, so with an
  `/etc/wpa_supplicant/wpa_supplicant.conf` it starts as before.

HOST, in the directory holding `aports` and `alpine-riscv32`, as for the
other patches:

```sh
git -C aports am "$PWD"/alpine-riscv32/patches/0013-*.patch
```

#### Sources and build

CONTAINER `alpine-rv32`, as your user:

```sh
cd /work/aports
for p in main/libevent main/tmux main/less main/tree main/ncdu main/coreutils community/bmake community/lowdown community/btop main/libidn2 main/lz4 main/popt main/xxhash main/rsync main/dtc community/i2c-tools community/evtest community/memtester main/dosfstools main/musl-fts community/exfatprogs main/libnl3 main/iw main/wireless-regdb main/wpa_supplicant main/iperf3 main/libmnl main/ethtool main/socat main/lua5.4; do (cd $p && abuild fetch verify) || break; done
```

CONTAINER `rv32-native`, as your user, with the same two variables as
above:

```sh
export ABUILD_BOOTSTRAP=1 APORTS_BOOTSTRAP=1
cd /work/aports
for p in main/libevent main/tmux main/less main/tree main/ncdu main/coreutils community/bmake community/lowdown community/btop main/libidn2 main/lz4 main/popt main/xxhash main/rsync main/dtc community/i2c-tools community/evtest community/memtester main/dosfstools main/musl-fts community/exfatprogs main/libnl3 main/iw main/wireless-regdb main/wpa_supplicant main/iperf3 main/libmnl main/ethtool main/socat main/lua5.4; do (cd $p && abuild -r) || break; done
```

The order follows the dependencies: each library comes right before the
first package that needs it, and bmake before lowdown before btop.

### Developer and network tools

cmake, curl, git, wget, gdb, tcpdump, iproute2, nmap and the full openssh
(client and `sftp-server`). Built after the two batches above, they need
27 source packages with four more edits, patches 0014 to 0017. Without the
edits curl alone would need 44 and git 54, nearly all of it the Python
modules behind cmake's manual.

| Patch | Package | Left out when bootstrapping | Why it matters |
| --- | --- | --- | --- |
| 0014 | cmake | the man pages (`--sphinx-man`, py3-sphinx) | sphinx is about 30 Python modules; brotli, c-ares (both for curl) and tcpdump build with cmake |
| 0015 | elfutils | the debuginfod client and server | they need curl, gnutls, libmicrohttpd and json-c; gdb and iproute2 only need libelf and libdw |
| 0016 | git | xmlto in the base `makedepends` | it is only used for the man pages, which git already skips when bootstrapping |
| 0017 | gdb | the second full build for `gdb-multiarch`, and `--with-debuginfod` | debuginfod is gone with 0015; the APKBUILD itself notes `--enable-targets=all` is broken on 32-bit targets since GDB 12.1 |

Each patch's commit message has the details; the diffs are in
[`patches/`](../../patches/).

- strace is not in the list: it has no riscv32 port (`src/linux/` has
  `riscv64` only, and `configure.ac` knows only `riscv64*`), so it would
  stop at `configure`. That is a porting job of its own.
- gdb has RISC-V Linux support, but nobody in this project has built it
  for riscv32 yet; it is the one most likely to need a fix. It builds last
  in the loop, so the others are done if it stops.

HOST, in the directory holding `aports` and `alpine-riscv32`:

```sh
git -C aports am "$PWD"/alpine-riscv32/patches/001[4567]-*.patch
```

CONTAINER `alpine-rv32`, as your user:

```sh
cd /work/aports
for p in main/libarchive main/libuv main/rhash main/cmake main/groff main/brotli main/c-ares main/libpsl main/libev main/nghttp2 main/curl main/perl-error main/git main/wget main/argp-standalone main/musl-obstack main/elfutils main/libpcap main/tcpdump main/jansson main/libnftnl main/iptables main/iproute2 main/pcre main/nmap main/openssh main/gdb; do (cd $p && abuild fetch verify) || break; done
```

CONTAINER `rv32-native`, as your user:

```sh
export ABUILD_BOOTSTRAP=1 APORTS_BOOTSTRAP=1
cd /work/aports
for p in main/libarchive main/libuv main/rhash main/cmake main/groff main/brotli main/c-ares main/libpsl main/libev main/nghttp2 main/curl main/perl-error main/git main/wget main/argp-standalone main/musl-obstack main/elfutils main/libpcap main/tcpdump main/jansson main/libnftnl main/iptables main/iproute2 main/pcre main/nmap main/openssh main/gdb; do (cd $p && abuild -r) || break; done
```

The order follows the dependencies: cmake first, because brotli and
c-ares build with it, then curl's libraries, curl, git; elfutils before
iproute2 and gdb; libpcap before tcpdump and nmap.

Done when: nano and dropbear are built in `rv32-native`, and `ssh` into the
QEMU machine prints `riscv32`.
Next: step 12, Alpine binaries on the board under Buildroot.
