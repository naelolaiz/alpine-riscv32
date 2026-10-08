# alpine-riscv32

Generic Alpine Linux support for 32-bit RISC-V (`riscv32`, `ilp32` soft-float,
musl). Nothing here is specific to a board; the first target is the ESP32-S31
in the sibling `esp32s31-alpine` repository, but the
result should also run on QEMU, LiteX or any other RV32 Linux system.

## Target

| | |
| --- | --- |
| Arch name | `riscv32` |
| Triplet | `riscv32-alpine-linux-musl` |
| ISA / ABI | `rv32imac` / `ilp32` (soft-float) |
| libc | musl (riscv32 upstream since 1.2.5), time64 |
| Loader | `/lib/ld-musl-riscv32-sf.so.1` (musl adds `-sf` for the soft-float ABI) |

## Status

The six patches in `patches/` are enough to cross-build Alpine's bootstrap
list for riscv32 (156 packages, alpine-base included) and to boot it under
`qemu-system-riscv32 -M virt` with mainline Linux 6.18 (`rv32_defconfig`) to
an OpenRC login, with `apk add` working inside the VM. Beyond that list,
packages build natively in a riscv32 container run through qemu-user:
dropbear and nano so far, with dropbear accepting SSH logins in the VM.
Per-package details are
in [`RISCV32.md`](RISCV32.md); the steps are in [`docs/steps/`](docs/steps/).

## Approach

Patches live here as a series against a pinned
[aports](https://gitlab.alpinelinux.org/alpine/aports) commit rather than as a
full aports fork, so the delta stays small and reviewable:

- [`aports.commit`](aports.commit): the aports commit the series applies to (master, 2026-10-06).
- [`docs/steps/`](docs/steps/): how to set up the build environment and make the edits by hand.
- `patches/`: `git format-patch` output, one fix per patch, numbered in apply order.
- [`ci/`](ci/) and [`.github/workflows/packages.yml`](.github/workflows/packages.yml):
  GitHub Actions builds the series and publishes the packages on GitHub Pages
  ([guide](docs/steps/23-package-ci.md)).
- `scripts/`: apply the series to a fresh aports checkout and run
  `scripts/bootstrap.sh riscv32` in an Alpine edge container.
- [`RISCV32.md`](RISCV32.md): package status table.
- `docs/`: the `riscv64` audit and notes per package.

When the series is ready to upstream, it is applied to an aports branch and
submitted to Alpine, coordinating in #alpine-ports.

## Already supported upstream

abuild maps `riscv32` to `riscv32-alpine-linux-musl`, and apk-tools reports
`riscv32` when built for rv32. The work is in the APKBUILDs (gcc, musl,
openssl, binutils) and `scripts/bootstrap.sh`.
