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
