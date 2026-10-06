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
podman exec -u root alpine-rv32 sh -c "mkdir -p $HOME && chown $(id -u):$(id -g) $HOME"
```

- `alpine-sdk` pulls in abuild, build-base (gcc, make, musl-dev) and git.
- Members of the `abuild` group may install build dependencies through
  `abuild-apk` without being root.
- `keep-id` adds your user to the container's `/etc/passwd` with your host home
  path, but the directory does not exist in the image. abuild keeps its signing
  key and settings in `~/.abuild`, so it must.

## 4. Enter and check

```sh
podman exec -it alpine-rv32 sh
```

Inside the container:

```sh
id
abuild -V
CTARGET=riscv32 sh -c '. /usr/share/abuild/functions.sh; echo "$CTARGET_ARCH $CTARGET $CBUILDROOT"'
```

- `id` must list the `abuild` group.
- The last line asks abuild what it derives from the arch name: the triplet
  `riscv32-alpine-linux-musl` and the sysroot where cross-built packages land.
  This is what "abuild already knows riscv32" means in practice.

## 5. Signing key

```sh
abuild-keygen -a -n
exit
podman exec -u root alpine-rv32 sh -c "cp $HOME/.abuild/*.rsa.pub /etc/apk/keys/"
```

Every package abuild builds is signed. apk installs only packages signed by a
key in `/etc/apk/keys`, so the public key goes there; `bootstrap.sh` also
copies it into the riscv32 sysroot. `-a` writes the key name into
`~/.abuild/abuild.conf`, `-n` skips the passphrase.

Done when: `id` shows `abuild`, and abuild prints the riscv32 triplet.
Next: part 2, the riscv32 edits to gcc, musl, openssl, binutils and bootstrap.sh.
