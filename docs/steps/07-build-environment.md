# Step 7, part 1: Alpine build environment

Alpine's `scripts/bootstrap.sh` calls `abuild` and `apk`, so it must run on
Alpine itself. On another distribution, an Alpine edge container provides
that. Edge, because the pinned aports commit is from the development branch,
whose tools (abuild, apk-tools) must match.

All host commands run from the directory that holds this repository and
`esp32s31-alpine`. It is mounted at `/work` in the container.

## 1. Get aports at the pinned commit

```sh
git clone --filter=blob:none https://gitlab.alpinelinux.org/alpine/aports.git
git -C aports switch -c riscv32 $(cat alpine-riscv32/aports.commit)
```

- `--filter=blob:none` downloads the history but fetches file contents only
  when needed: aports is large, and only one commit is checked out.
- [`aports.commit`](../../aports.commit) pins the tree. aports changes every
  day; a fixed commit keeps the patch series in this repository applicable.
  The `riscv32` branch is where the edits of part 2 go.

## 2. Start the container

```sh
podman run -d --name alpine-rv32 --userns=keep-id -v "$PWD":/work:Z -w /work docker.io/library/alpine:edge sleep infinity
```

- `-d ... sleep infinity`: a container that keeps running, to enter as often
  as needed with `podman exec`. `podman stop alpine-rv32` and
  `podman start alpine-rv32` keep its installed packages.
- `--userns=keep-id`: your user inside the container has the same UID as on
  the host, so files written in `/work` belong to you, not to a mapped root.
  abuild also refuses to build as root.
- `-v "$PWD":/work:Z`: the host directory is shared, so edits made on the host
  are seen inside. `:Z` relabels it for SELinux and is ignored without it.

## 3. Install the build tools (as root in the container)

```sh
podman exec -u root alpine-rv32 apk add alpine-sdk
podman exec -u root alpine-rv32 addgroup $(id -un) abuild
```

- `alpine-sdk` pulls in abuild, build-base (gcc, make, musl-dev) and git.
- Members of the `abuild` group may install build dependencies through
  `abuild-apk` without being root.

With `keep-id`, podman adds your user to the container's `/etc/passwd` with the
working directory as home, so `HOME` is `/work` inside. abuild keeps its
signing key in `$HOME/.config/abuild` and puts built packages in
`$HOME/packages`; both end up on the host, next to the repositories, and
survive removing the container.

## 4. Signing key

Enter the container. Commands after this line run inside it; type them at its
prompt rather than pasting them together with the `podman exec` line, or the
terminal hands them to the host shell once the container shell exits.

```sh
podman exec -it alpine-rv32 sh
```

Inside:

```sh
abuild-keygen -a -n
exit
```

Back on the host, trust the public key in the container:

```sh
podman exec -u root alpine-rv32 sh -c 'cp /work/.config/abuild/*.rsa.pub /etc/apk/keys/'
```

Every package abuild builds is signed, and apk installs only packages signed
by a key in `/etc/apk/keys`. `-a` writes the key name into
`.config/abuild/abuild.conf`, `-n` skips the passphrase. The key name starts
with `PACKAGER`'s e-mail, git's `user.email` or `$USER`; with none set inside
the container it starts with `-`, which is harmless.

## 5. Check

```sh
podman exec -it alpine-rv32 sh
```

Inside:

```sh
echo $HOME
id
abuild -V
ls /etc/apk/keys
CTARGET=riscv32 sh -c '. /usr/share/abuild/functions.sh; echo "$CTARGET_ARCH $CTARGET $CBUILDROOT"'
```

- `id` must list the `abuild` group.
- `/etc/apk/keys` must contain your key next to Alpine's.
- The last line asks abuild what it derives from the arch name: the triplet
  `riscv32-alpine-linux-musl` and the sysroot where cross-built packages land.
  This is what "abuild already knows riscv32" means in practice.

## Found here: bootstrap.sh looks for the key in the old place

abuild moved its user directory from `~/.abuild` to `~/.config/abuild` (it
still uses `~/.abuild` if only that exists; `functions.sh` sets
`ABUILD_USERDIR`). `scripts/bootstrap.sh` still runs
`cp -a ~/.abuild/*.pub "$CBUILDROOT/etc/apk/keys"`, which fails with a fresh
key, and the script stops there (`set -e`). The fix is part of part 2:
use `"$ABUILD_USERDIR"/*.pub`. It is generic, not riscv32-specific.

Done when: `id` shows `abuild`, the key is in `/etc/apk/keys`, and abuild
prints the riscv32 triplet.
Next: part 2, the edits to gcc, musl, openssl, binutils and bootstrap.sh.
