# Step 10: boot the riscv32 base system in QEMU

Step 9 produced the packages. This step boots them in an emulated riscv32
machine, `qemu-system-riscv32 -M virt`, with a mainline Linux 6.18 kernel:

- QEMU's built-in OpenSBI starts the kernel, as OpenSBI does on the board.
- The root file system is an ext4 disk image built from the local repository.
- The goal is OpenRC up to a login prompt on the serial console, then
  `apk add` from the local repository.

## 1. Kernel source

HOST, in the directory holding `aports`. Download 6.18 and kernel.org's
checksum list and compare them, because a broken tarball only shows up later
as strange build errors. Unpacking on the host keeps the tree owned by the host
user.

```sh
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.tar.xz
curl -fLO https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc
grep ' linux-6.18.tar.xz$' sha256sums.asc
sha256sum linux-6.18.tar.xz
tar xf linux-6.18.tar.xz
```

The two sums must match.

## 2. Tools in the container

CONTAINER, entered with `podman exec -it -u $(id -un) alpine-rv32 sh`:

- The cross compiler comes from the local repository again, because abuild
  removes build dependencies after every package.
- flex, bison, perl, bc and openssl-dev are what the kernel's build helpers
  need.
- ncurses-dev lets `make menuconfig` draw its menus.
- qemu-system-riscv32 is the emulator. It ships OpenSBI as
  `/usr/share/qemu/opensbi-riscv32-generic-fw_dynamic.bin`, which QEMU loads
  by default.

```sh
abuild-apk add --repository /work/.local/share/abuild/main gcc-riscv32 binutils-riscv32
abuild-apk add flex bison perl bc openssl-dev ncurses-dev linux-headers qemu-system-riscv32
```

## 3. Configure and build

CONTAINER:

```sh
cd /work/linux-6.18
make ARCH=riscv CROSS_COMPILE=riscv32-alpine-linux-musl- rv32_defconfig
make ARCH=riscv CROSS_COMPILE=riscv32-alpine-linux-musl- -j$(nproc) Image
ls -l arch/riscv/boot/Image
```

- `ARCH=riscv` selects the kernel's riscv code, and `CROSS_COMPILE` is the
  prefix of the cross tools from step 8.
- `rv32_defconfig` is a target in `arch/riscv/Makefile`. It is riscv's
  `defconfig` plus `arch/riscv/configs/32-bit.config` (`CONFIG_ARCH_RV32I`,
  `CONFIG_32BIT`, `CONFIG_NONPORTABLE`).
- The defconfig already has what QEMU's virt machine needs:

  | Need | Options |
  | --- | --- |
  | Disk and network | `CONFIG_VIRTIO_BLK`, `CONFIG_VIRTIO_NET` |
  | Bus for virtio devices | `CONFIG_VIRTIO_PCI`, `CONFIG_PCI_HOST_GENERIC` |
  | Root file system | `CONFIG_EXT4_FS` |
  | Serial console | `CONFIG_SERIAL_8250`, `CONFIG_SERIAL_8250_CONSOLE` |
  | Device nodes | `CONFIG_DEVTMPFS`, `CONFIG_DEVTMPFS_MOUNT` |

- `Image` builds only the kernel. The default target also builds the modules
  marked `=m`, which this boot does not need.
- The kernel compiles C with `-mabi=ilp32` and no F/D instructions, but its
  assembler gets `fd` for saving the FPU state of processes that use it. The
  soft-float cross gcc from step 8 builds it unchanged. The board's core has no
  FPU; its own kernel is Espressif's.

## 4. Let the host run riscv32 programs (binfmt_misc)

apk runs each package's install scripts inside the new tree, and they are
riscv32 programs: busybox's creates every applet link, `/sbin/init` among
them. The host kernel can run a foreign program only if a binfmt_misc rule
hands it to an interpreter. Step 11's build chroot needs the same rule.
Alpine's `qemu-riscv32` is statically linked and ships the rule.

CONTAINER, as your user. Copy the interpreter and the rule into `/work`,
because the host kernel has to open the interpreter as a file it can see.
`file` must say statically linked: the kernel will use this exact binary
inside the container too, where the host's libraries do not exist.

```sh
cp /usr/bin/qemu-riscv32 /work/qemu-riscv32-static
cp /usr/lib/binfmt.d/qemu-riscv32.conf /work/
file /work/qemu-riscv32-static
```

HOST, in the directory holding `aports`. Point the rule at the copy and
register it; registering needs root:

```sh
cat qemu-riscv32.conf
sed "s|/usr/bin/qemu-riscv32|$PWD/qemu-riscv32-static|" qemu-riscv32.conf | sudo tee /proc/sys/fs/binfmt_misc/register
cat /proc/sys/fs/binfmt_misc/qemu-riscv32
```

The fields are `:name:type:offset:magic:mask:interpreter:flags`:

- `M` matches on magic bytes.
- The magic is the start of an ELF header: 32-bit, little-endian, machine
  `\xf3\x00` (0xf3 is RISC-V). The mask ignores the bytes that vary, and
  its `\xfe` accepts both `ET_EXEC` and `ET_DYN` (PIE) files.
- Flag `F` opens the interpreter once, at registration, so it also works
  inside containers and chroots.
- Flag `P` keeps the program's own argv[0].

The rule lasts until reboot. `echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-riscv32`
removes it earlier.

CONTAINER as root (`podman exec -it -u root alpine-rv32 sh`). This runs a
riscv32 program with no qemu in the command, using the tree from step 9:

```sh
chroot /var/tmp/rootfs-riscv32 /bin/busybox uname -m
```

It prints `riscv32`.

## 5. The root tree, with install scripts

CONTAINER as root. Use a fresh tree: the one from step 9 was installed with
`--no-scripts`, so it has no applet links. `e2fsprogs` provides `mkfs.ext4`
for section 6. apk itself chroots into the tree to run each script, and the
binfmt rule from section 4 lets those riscv32 scripts run.

```sh
apk add e2fsprogs
mkdir -p /var/tmp/alpine-rv32-root/etc/apk/keys
cp /work/.config/abuild/*.rsa.pub /var/tmp/alpine-rv32-root/etc/apk/keys/
apk add --root /var/tmp/alpine-rv32-root --initdb --arch riscv32 --repository /work/.local/share/abuild/main alpine-base
ls -l /var/tmp/alpine-rv32-root/sbin/init
```

`/sbin/init` is a link to `/bin/busybox` that busybox's install script
created; if it is missing, the scripts did not run.

Expected warning: `busybox-1.38.0-r7: failed to create initial device nodes:
Operation not permitted`. Before running scripts, apk tries to create
`/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom` and `/dev/console` in
the tree, and a rootless container may not create device nodes. It does not
matter for the boot: the kernel mounts devtmpfs over `/dev`
(`CONFIG_DEVTMPFS_MOUNT=y`).

Then the settings a boot needs, still CONTAINER as root:

1. A login prompt on the serial console. QEMU's `-nographic` shows only the
   first serial port, `ttyS0`; the `tty1` to `tty6` gettys are for a screen.
   `etc/inittab` ships the line commented out:

   ```diff
   /var/tmp/alpine-rv32-root/etc/inittab:16
   -#ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
   +ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
   ```

   ```sh
   sed -i 's|^#ttyS0::|ttyS0::|' /var/tmp/alpine-rv32-root/etc/inittab
   grep ttyS0 /var/tmp/alpine-rv32-root/etc/inittab
   ```

2. The root file system in `fstab`, so OpenRC knows what `/` is and how to
   check and remount it:

   ```sh
   echo '/dev/vda	/	ext4	rw,relatime	0 1' >> /var/tmp/alpine-rv32-root/etc/fstab
   cat /var/tmp/alpine-rv32-root/etc/fstab
   ```

3. A host name, which the `hostname` service sets at boot:

   ```sh
   echo alpine-rv32 > /var/tmp/alpine-rv32-root/etc/hostname
   ```

4. OpenRC services. Packages install services but do not enable them;
   `rc-update add` creates the links in `/etc/runlevels/`. It runs inside the
   tree through the binfmt rule.

   | Service | Runlevel | Why |
   | --- | --- | --- |
   | devfs | sysinit | mounts `/dev/pts` and `/dev/shm` on the kernel's devtmpfs |
   | dmesg | sysinit | sets the console log level |
   | mdev | sysinit | busybox's device manager: device permissions from `/etc/mdev.conf`, hotplug |
   | hostname | boot | sets the host name from `/etc/hostname` |
   | bootmisc | boot | prepares `/var/run` and the login records (utmp, wtmp) |
   | sysctl | boot | applies `/etc/sysctl.conf` and `/etc/sysctl.d` |
   | syslog | boot | busybox syslogd, so `/var/log/messages` exists |
   | killprocs | shutdown | stops leftover processes |
   | mount-ro | shutdown | remounts `/` read-only before power off |

   ```sh
   chroot /var/tmp/alpine-rv32-root rc-update add devfs sysinit
   chroot /var/tmp/alpine-rv32-root rc-update add dmesg sysinit
   chroot /var/tmp/alpine-rv32-root rc-update add mdev sysinit
   chroot /var/tmp/alpine-rv32-root rc-update add hostname boot
   chroot /var/tmp/alpine-rv32-root rc-update add bootmisc boot
   chroot /var/tmp/alpine-rv32-root rc-update add sysctl boot
   chroot /var/tmp/alpine-rv32-root rc-update add syslog boot
   chroot /var/tmp/alpine-rv32-root rc-update add killprocs shutdown
   chroot /var/tmp/alpine-rv32-root rc-update add mount-ro shutdown
   ```

Alpine's `root` account has an empty password (`root::` in `etc/shadow`),
so the console login needs none. Set one before this system is reachable
over a network.

## 6. The disk image

CONTAINER as root. `mkfs.ext4 -d` creates the file system and copies the tree
into it, owners included, without mounting anything (a rootless container
cannot mount). 256M leaves room for `apk add`. Files that container root
creates in `/work` would belong to a subordinate uid on the host, so the
directory and the image are handed to the owner of `/work`, which is the host
user.

```sh
install -d -o "$(stat -c %u /work)" -g "$(stat -c %g /work)" /work/qemu
mkfs.ext4 -d /var/tmp/alpine-rv32-root -L alpine-rv32 /work/qemu/alpine-rv32.img 256M
chown "$(stat -c %u:%g /work)" /work/qemu/alpine-rv32.img
```

## 7. Boot

CONTAINER, as your user:

```sh
qemu-system-riscv32 -M virt -m 256M -nographic \
	-kernel /work/linux-6.18/arch/riscv/boot/Image \
	-append "root=/dev/vda rw console=ttyS0" \
	-drive file=/work/qemu/alpine-rv32.img,format=raw,if=virtio
```

- `-M virt` is QEMU's generic RISC-V board. Its default `-bios` is OpenSBI,
  which starts the kernel in supervisor mode, as on the ESP32-S31.
- `-nographic` puts the first serial port on the terminal.
- `root=/dev/vda` is the first virtio disk, and `console=ttyS0` sends kernel
  messages to that serial port.
- Ctrl-A then X quits QEMU.

At the login prompt, `root` needs no password. OpenRC also starts services
the enabled ones depend on (modules, hwclock, sysfs, fsck, root, localmount);
`rc-status -a` lists them under "needed/wanted".

In the VM, `poweroff` shuts down through the shutdown runlevel (killprocs,
mount-ro), which closes the ext4 image cleanly; Ctrl-A X is like pulling the
plug.

## 8. apk add inside the VM

The local repository reaches the VM over virtio-9p, a file-sharing channel
between QEMU and the guest (`CONFIG_9P_FS` and `CONFIG_NET_9P_VIRTIO` are in
the defconfig). CONTAINER, as your user, the same boot plus `-virtfs`:

```sh
qemu-system-riscv32 -M virt -m 256M -nographic \
	-kernel /work/linux-6.18/arch/riscv/boot/Image \
	-append "root=/dev/vda rw console=ttyS0" \
	-drive file=/work/qemu/alpine-rv32.img,format=raw,if=virtio \
	-virtfs local,path=/work/.local/share/abuild,mount_tag=repo,security_model=none,readonly=on
```

- `path` is the directory to share; `mount_tag` is the name the guest mounts.
- `security_model=none` reads the files with QEMU's own permissions.
- `readonly=on` keeps the VM from changing the repository.

In the VM, as root. `trans=virtio` selects the transport and `9p2000.L` the
Linux dialect of the protocol. apk appends the architecture (`riscv32`) to the
repository path itself, and the signing key is already in `/etc/apk/keys`:

```sh
mount -t 9p -o trans=virtio,version=9p2000.L repo /mnt
apk add --repository /mnt/main file
file /bin/busybox
```

`file` prints `ELF 32-bit LSB pie executable, UCB RISC-V, RVC, soft-float ABI
... interpreter /lib/ld-musl-riscv32-sf.so.1`.

Done when: OpenRC starts the services above, `alpine-rv32 login:` accepts
`root`, and `apk add` installs from the local repository.
