# Step 23, part 1: building the packages on GitHub Actions

Steps 8, 9 and 11 build every package on the PC. The workflow in
[`.github/workflows/packages.yml`](../../.github/workflows/packages.yml) does
the same on GitHub's machines and publishes the result as an apk repository
on GitHub Pages. Adding a package then means adding one line (and a patch,
if its APKBUILD needs an edit) and pushing.

It works because a GitHub-hosted runner is an x86_64 Ubuntu virtual machine
where the workflow has root through `sudo` and Docker: the same containers
and the same binfmt_misc rule as on the PC. Runners for public repositories
cost nothing; each job may run for at most 6 hours.

## What a run does

| Job | PC equivalent | What it does |
| --- | --- | --- |
| `cross` | steps 7 to 9 | aports at `aports.commit` plus `patches/`, `bootstrap.sh riscv32`, then `bootstrap.sh riscv32 mdev-conf` |
| `native` | step 11 | a riscv32 container from those packages; `abuild -r` for every line of [`ci/native-packages.txt`](../../ci/native-packages.txt) |
| `publish` | step 15's `http.server` | the repository directory, as it is on the PC under `.local/share/abuild`, published on GitHub Pages; main only |

Every run starts by downloading what the last run published. abuild skips
a package whose `.apk` files already exist, so a run only builds what is new
or changed. The first run builds everything and takes hours; later runs take
minutes plus whatever changed.

## 1. One-time setup

### Signing key

apk installs only packages signed by a key in `/etc/apk/keys` (step 15).
Your key from step 7 stays on the PC; the workflow gets its own, so the
private half never has to leave a place you control except into GitHub's
secret store.

HOST, in the directory holding `aports`. Outside both repositories, so git
never sees the private key (`.gitignore` also excludes `*.rsa` as a guard):

```sh
openssl genrsa -out alpine-riscv32-ci.rsa 4096
openssl rsa -in alpine-riscv32-ci.rsa -pubout -out alpine-riscv32-ci.rsa.pub
```

- These are the two commands `abuild-keygen` runs. The name matters: abuild
  stores the public key's file name in every signature, and apk looks for
  that name in `/etc/apk/keys`. The workflow expects `alpine-riscv32-ci.rsa`.
- Keep `alpine-riscv32-ci.rsa` somewhere safe and offline as well. Anyone
  with it can sign packages that every board trusting this key installs.

### Secret

GitHub, repository alpine-riscv32: Settings, Secrets and variables, Actions,
New repository secret. Name `ABUILD_PRIVKEY`, value the whole file, the
`-----BEGIN` and `-----END` lines included. HOST, to print it for copying:

```sh
cat alpine-riscv32-ci.rsa
```

A secret is handed only to workflow runs of this repository, never to pull
requests from forks, and GitHub replaces its text with `***` in the logs.

Without the secret, runs on main stop at once. Runs on other branches build
everything from scratch with a temporary key and publish nothing, which
tests the workflow without any setup.

### GitHub Pages

Settings, Pages, Build and deployment, Source: GitHub Actions. The
`publish` job then deploys the repository directory directly. No branch
holds the packages, so no binary ever enters git history.

## 2. Run it

Push to main any change under `aports.commit`, `patches/`, `ci/` or the
workflow file, or start it by hand: Actions tab, riscv32 packages, Run
workflow. Each step's log is on the run page; the `native` job's summary
lists every package with its build time, the failures, and any package
left for the next run.

## 3. How it works, step by step

The workspace looks like the directory on the PC that holds `aports` and
the repositories, and it is mounted at `/work` in every container, so the
paths in the logs are the ones from steps 7 to 11.

### Prepare (`ci/prepare.sh`, both build jobs)

- **aports**: `git fetch --depth 1` of the pinned commit, then `git am` of
  `patches/`. A shallow fetch downloads one tree instead of aports' whole
  history; `git am` applies the series exactly as `format-patch` wrote it.
- **key and `abuild.conf`**: the secret becomes
  `.config/abuild/alpine-riscv32-ci.rsa`, and `abuild.conf` names it
  (`PACKAGER_PRIVKEY`), sets `SRCDEST` as in step 8 and
  `DISTFILES_MIRROR` as in step 11, section 8, so abuild tries Alpine's
  copy of each source before the original server.
- **container `alpine-rv32`**: `alpine:edge` with `alpine-sdk`, as in step 7.
  Docker has no `--userns=keep-id`, so the script adds the user by hand:
  `builder`, with the runner's uid, so files written in `/work` belong to
  the runner, and home `/work`, so abuild finds its settings there. The
  public key goes into `/etc/apk/keys`, because abuild installs the cross
  compiler it built from its own repository.

### Downloaded sources

`actions/cache` keeps `.cache/distfiles` between runs, so gcc and binutils
are not downloaded every time. Each run saves a new copy; GitHub drops the
oldest when the repository's caches pass 10 GB.

### Published packages (`ci/fetch-published.sh`)

Downloads every file listed in the published `files.txt` into
`.local/share/abuild`. Then abuild's own test decides what to build: a
package is up to date when all its `.apk` files exist, none of its sources
or its APKBUILD is newer, and the index is newer than the `.apk` files.
The fresh checkout and the restored cache are newer than the download, so
the build steps first touch every `.apk`, then every `APKINDEX.tar.gz`.

Consequence: a change to an APKBUILD that keeps the version is not rebuilt.
Bump `pkgrel`, the rule aports follows anyway.

### Cross job

`bootstrap.sh riscv32` runs as in step 9, then once more for mdev-conf,
which its list lacks (step 9, section 4). On a later run every package is
up to date and both calls take a minute.

### Native job

1. `abuild fetch verify` for each listed package in `alpine-rv32`, as in
   step 11, section 5: downloading needs no emulation.
2. Alpine's static `qemu-riscv32` and its binfmt_misc rule are copied out
   of `alpine-rv32` and registered with the flags `OCFP` (step 10,
   section 4, and step 11, section 1).
3. The riscv32 tree is built with `apk add --root` and imported as an image
   (step 11, sections 2 and 3, with `docker import` instead of
   `podman import`).
4. `ci/native-build.sh` runs `abuild -r` per line with
   `ABUILD_BOOTSTRAP=1 APORTS_BOOTSTRAP=1`, as in step 11, sections 6 and 8.
   A failing package does not stop the loop: the others are still built and
   published, and the job ends red. After `budget-minutes` (300 by default)
   it starts no new package, so there is time left to publish; the next run
   continues where this one stopped.

### Publish job

Writes `files.txt` and a small `index.html`, then deploys. The site is the
repository directory, so its layout is the one apk expects:
`https://naelolaiz.github.io/alpine-riscv32/main/riscv32/APKINDEX.tar.gz`,
with the public key at the top. It runs after a failure too, so finished
packages are not lost.

Why Pages and not a GitHub release: apk appends `/<arch>/APKINDEX.tar.gz`
to the repository URL and fetches packages next to the index, while a
release is a flat list of files. GitHub's API documentation also says it
renames uploaded release files with special characters, and `libstdc++` and
`g++` contain `+` (not tested whether `+` counts). A Pages deploy
also replaces the whole site at once, so a board never sees a new index
next to missing packages.

## 4. Adding a package

1. If its APKBUILD needs an edit, make it in `aports` and add the patch to
   `patches/` as for the others (`git format-patch`).
2. Add its directory (`main/htop`) to `ci/native-packages.txt`, after the
   packages it needs to build. abuild installs build dependencies only from
   what is built so far.
3. Push to main.

To try a package first, push to another branch. That run builds on top of
the published packages and publishes nothing; its result is the `repo`
artifact on the run page.

## 5. On the board

The packages go onto the stick, as long as the board has no network. HOST,
with the stick in the PC. Mounting by label avoids guessing the device
name, which differs between the PC and the board:

```sh
sudo mount LABEL=alpine-root /mnt
curl -fsSL https://naelolaiz.github.io/alpine-riscv32/files.txt | grep -e '/riscv32/' -e '\.rsa\.pub$' | sed 's|^|https://naelolaiz.github.io/alpine-riscv32/|' | sudo wget -q -x -nH --cut-dirs=1 -P /mnt/root/ci-packages -i -
sudo umount /mnt
```

- `grep` keeps the riscv32 packages and the key; the cross compiler in
  `x86_64/` is of no use on the board.
- `-x -nH --cut-dirs=1` keeps the path below the site (`main/riscv32/...`),
  which is the layout apk expects.

BOARD, as root, after booting from the stick:

```sh
cp /root/ci-packages/alpine-riscv32-ci.rsa.pub /etc/apk/keys/
apk add --repositories-file /dev/null --repository /root/ci-packages/main nano
```

`--repositories-file /dev/null` leaves out the PC's server from step 15,
which the board cannot reach without the cable.

## Not tested yet

This is a draft: no run has finished yet. Its first run will show
whether these hold:

- The whole bootstrap fits in the `cross` job's 6 hours on a 4-core runner.
- GitLab answers a shallow fetch of one commit (the script falls back to
  GitHub's aports mirror).
- `alpine:edge` on the day of the run still builds the pinned aports commit,
  as it did on the PC.
- Docker's default seccomp profile lets qemu-user run everything abuild does.
- Old versions stay in the repository after a `pkgrel` bump; nothing prunes
  them yet. GitHub Pages allows 1 GB per site.
- A new signing key needs a full rebuild, and the workflow has no switch for
  that yet: the old packages would fail apk's signature check.
- Over HTTPS (Wi-Fi later), the board needs a roughly correct clock to accept
  the github.io certificate.
