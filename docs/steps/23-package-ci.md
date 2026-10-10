# Step 23, part 1: building the packages on GitHub Actions

Steps 8, 9 and 11 build every package on the PC. The workflow in
[`.github/workflows/packages.yml`](../../.github/workflows/packages.yml) does
the same on GitHub's machines. A push builds only what is new or changed
and, on main, publishes the result as an apk repository on GitHub Pages. A
pushed `packages-*` tag builds everything from scratch and publishes it as
the GitHub release of that tag, a dated snapshot like the first one,
packages-2026-10-10, which was built on the PC and packed by hand. Adding a
package means adding one line (and a patch, if its APKBUILD needs an edit)
and pushing; only that package is built.

It works because a GitHub-hosted runner is an x86_64 Ubuntu virtual machine
where the workflow has root through `sudo` and Docker: the same containers
and the same binfmt_misc rule as on the PC. Runners for public repositories
cost nothing; each job may run for at most 6 hours.

## What a run does

| Job | PC equivalent | What it does |
| --- | --- | --- |
| `cross` | steps 7 to 9 | aports at `aports.commit` plus `patches/`, `bootstrap.sh riscv32`, then `bootstrap.sh riscv32 mdev-conf` |
| `native-1` to `native-4` | step 11 | a riscv32 container from those packages; `abuild -r` for every line of [`ci/native-packages.txt`](../../ci/native-packages.txt). A part runs only if the one before ran out of time |
| `pages` | step 15's `http.server` | the riscv32 part of the repository directory, as it is on the PC under `.local/share/abuild`, published on GitHub Pages; main only |
| `release` | packing the release by hand | the same directories as one archive in a GitHub release, with the keys and `packages.txt`; `packages-*` tags only |

A push starts by downloading everything published: the Pages site plus the
newest `packages-*` release. abuild skips a package whose `.apk` files
already exist, so the run builds only what is new or changed: a new line
in the list, or a new `pkgver` or `pkgrel`. A run with nothing to build
takes about 15 minutes, mostly setting up the machines; one new package
adds its own build time.

A tag starts from an empty repository instead, so a release is one clean
build of everything at that commit. That takes many hours, which is why
the native builds may continue over up to four jobs of 6 hours each.

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

Settings, Pages, Build and deployment, Source: GitHub Actions. The `pages`
job then deploys the repository directory directly. No branch holds the
packages, so no binary ever enters git history. Until this is set, the
`pages` job fails at its last step (`deploy-pages` answers 404), as it did
on the first run on main.

Releases need no setting: the `release` job may create them because the
workflow gives it `contents: write`.

The secret is needed for tags as for main: without it, a tag run stops at
once, because its packages would be signed by a key no board trusts.

## 2. Run it

Push to main any change under `aports.commit`, `patches/`, `ci/` or the
workflow files, or start it by hand: Actions tab, riscv32 packages, Run
workflow. Each step's log is on the run page; each native part's summary
lists every package with its build time, the failures, and any package
left for the next part.

### Making a release

HOST, in your clone of alpine-riscv32, on the commit to release (usually
main after a pull). The tag name becomes the release name; use the date,
and a suffix for a second release on one day:

```sh
git switch main
git pull
git tag packages-2026-10-17
git push origin packages-2026-10-17
```

- `git tag` without `-a` makes a lightweight tag, a name for the commit;
  the release notes are written by the workflow.
- The push starts the run: the `tag` job checks that no release of that
  name exists, then everything is built from scratch, and the `release`
  job publishes the release, but only if every package was built. If one
  failed, or four native parts were not enough, there is no release, the
  run's summary says why, and the tag stays: delete it
  (`git push origin :refs/tags/packages-2026-10-17`, then
  `git tag -d packages-2026-10-17`) before pushing it again.
- A tag run does not update Pages; the next push to main carries on from
  Pages plus this release.

A release made by hand on the Releases page also creates its tag. The
`tag` job sees that the release exists and the run builds nothing; the
next push to main picks up its packages.

## 3. How it works, step by step

The workspace looks like the directory on the PC that holds `aports` and
the repositories, and it is mounted at `/work` in every container, so the
paths in the logs are the ones from steps 7 to 11.

### Prepare (`ci/prepare.sh`, every build job)

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

Some upstream servers do not answer the runners (gmplib.org timed out on
the first run). [`ci/sources.txt`](../../ci/sources.txt) lists those files
with another copy, as the curl commands in steps 8 and 9 do on the PC, and
`ci/prefetch-sources.sh` downloads them into `.cache/distfiles` first.
abuild still checks their sha512.

### Published packages (`ci/fetch-published.sh`)

Not for a tag. In this order:

1. Every file listed in the published `files.txt` goes into
   `.local/share/abuild`. If the site has nothing yet (`files.txt` answers
   404), this part is skipped. Any other error stops the run, because
   going on would rebuild everything and deploy a smaller repository over
   the old one.
2. The archive of the newest `packages-*` release is unpacked next to it,
   and each `.apk` that is missing or differs is copied over. Where both
   have a file of the same name, the release's wins: it is the build
   someone chose to publish. This is how a release built on the PC (the
   first one, with the natively built openssl, python3, htop, vim, mc and
   neofetch) reaches Pages without being built again.
3. The keys come along. A package that is carried over keeps the signature
   it was made with, so the repository mixes keys: the PC's
   (`-6ac57722.rsa.pub`) for what was built on the PC,
   `alpine-riscv32-ci.rsa.pub` for what the workflow builds. apk checks
   every package's own signature, not just the index's, so every key goes
   into `/etc/apk/keys` of `alpine-rv32` (`bootstrap.sh` copies that
   directory into its sysroot), and the native jobs put them into the
   riscv32 container. The board needs both keys too, and both are
   published.
4. Where the release added or replaced packages, the directory's
   `APKINDEX.tar.gz` no longer lists what is there, so the script writes a
   new one the way abuild does after a build: `apk index`, then
   `abuild-sign` with the workflow's key.

Then abuild's own test decides what to build: a package is up to date
when all its `.apk` files exist, none of its sources or its APKBUILD is
newer, and the index is newer than the `.apk` files. The fresh checkout
and the restored cache are newer than the download, so the build steps
first touch every `.apk`, then every `APKINDEX.tar.gz`.

Consequence: a change to an APKBUILD that keeps the version is not rebuilt.
Bump `pkgrel`, the rule aports follows anyway.

### Cross compiler (cache)

`bootstrap.sh` first builds the x86_64 cross compiler (binutils, gcc and
build-base for riscv32) into `main/x86_64`. It is of no use on a board, so
neither Pages nor the releases carry it; `actions/cache` keeps it instead.
Its key is a hash of the binutils, gcc and build-base directories in
aports, so a change to one of them builds it again (about an hour). If
GitHub drops the cache (after 7 days unused, or when the repository's
caches pass 10 GB), the next run builds it again as well. A tag run does
not use the cache: a release is built from scratch.

### Cross job

`bootstrap.sh riscv32` runs as in step 9, then once more for mdev-conf,
which its list lacks (step 9, section 4). On a later run every package is
up to date and both calls take a minute.

### Native jobs

The steps live in [`native.yml`](../../.github/workflows/native.yml), a
workflow that `packages.yml` calls up to four times in a row (`native-1`
to `native-4`). Each part takes the repository the job before it handed
on, skips what is built, and hands on the result. A part runs only when
the one before stopped starting packages for lack of time.

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
   it starts no new package, so there is time left to hand the repository
   on; the next part, or the next run, continues where this one stopped.
   A package still building at the step's limit (340 minutes) is stopped
   and built again from the start by the next part.
5. `main/openssl` carries the option `rebuild-if-cross`. The openssl that
   `bootstrap.sh` cross-builds has no thread support, which python3's ssl
   module needs (step 11, section 8). The script reads
   `usr/include/openssl/configuration.h` from the `openssl-dev` package in
   the repository; if it says `OPENSSL_NO_THREADS`, it builds openssl again
   natively with `abuild -r -f` (same version) and installs the new
   `libcrypto3` and `libssl3` in the container from their files, since apk
   would keep the installed ones of the same version. The first release
   already has the native openssl, so this happens only after a build from scratch.

### Pages job

Removes `x86_64/`, writes `files.txt` and a small `index.html` (the keys and
the lines for `/etc/apk/repositories`), then deploys. The site is the
repository directory, so its layout is the one apk expects:
`https://naelolaiz.github.io/alpine-riscv32/main/riscv32/APKINDEX.tar.gz`,
with the public keys at the top. It runs after a failed build too, so
finished packages are not lost, but not when a step before the builds
failed: that repository could lack what was published, and the deploy
would remove it from the site.

### Release job (`ci/make-release.sh`)

Runs for a tag only, after a complete build: the cross job green and the
last native part green with nothing left. Packs `main`, `community` and
`testing` for riscv32 into `alpine-riscv32-packages-DATE.tar.gz` (DATE is
the tag without `packages-`), lists every package as
`name version repository` in `packages.txt` (from the signed indexes), and
creates the release of the tag with the archive, the key and
`packages.txt`. The notes list what is new or rebuilt and what is gone
since the previous release, which commit and patches it was built from,
and how to install it.

### Pages and releases

They do different jobs, so the workflow publishes both:

- Pages is an apk repository. apk appends `/<arch>/APKINDEX.tar.gz` to a
  repository URL and fetches packages next to the index, so a board with
  network downloads only the index and what changed. A deploy replaces the
  whole site at once, so a board never sees a new index next to missing
  packages. It keeps no history, and a site may hold at most 1 GB.
- A release is a flat list of files, so apk cannot use it as a repository;
  the archive inside it can, once unpacked. It keeps every earlier
  snapshot, allows 2 GiB per file, and is the easiest way onto the stick
  while the board has no network. It is made only from a tag you push, so
  the list of releases stays a list of versions you chose, each one a
  clean build.

## 4. Adding a package

1. If its APKBUILD needs an edit, make it in `aports` and add the patch to
   `patches/` as for the others (`git format-patch`).
2. Add its directory (`main/htop`) to `ci/native-packages.txt`, after the
   packages it needs to build. abuild installs build dependencies only from
   what is built so far.
3. Push to main. The run builds that package (and nothing already
   published), and Pages has it when the run is done.

If its source server does not answer the runners, the log ends in
`ERROR: <package>: fetch failed`; add the file with another copy to
`ci/sources.txt`.

To try a package first, push to another branch. That run builds on top of
the published packages and publishes nothing; its result is the `repo`
artifact on the run page.

## 5. On the board

The board takes the packages from local directories on the stick while it
has no network, and from Pages once Wi-Fi works. Either way, apk finds them
through `/etc/apk/repositories`, so plain `apk add` and `apk upgrade` work
without `-X` flags.

### From a release, on the stick

HOST, in the directory you downloaded the release files to, with the stick
in the PC. Mounting by label avoids guessing the device name, which
differs between the PC and the board; removing the old `root/repo` drops
the packages the new release replaces:

```sh
sudo mount LABEL=alpine-root /mnt
sudo cp ./*.rsa.pub /mnt/etc/apk/keys/
sudo rm -rf /mnt/root/repo
sudo mkdir -p /mnt/root/repo
sudo tar -xzf alpine-riscv32-packages-2026-10-10.tar.gz -C /mnt/root/repo
sudo umount /mnt
```

- `./*.rsa.pub` copies both keys; the `./` keeps `cp` from reading
  `-6ac57722.rsa.pub` as an option.
- Use the archive name of the release you downloaded.

BOARD, as root, after booting from the stick. The first command is needed
once: apk reads local repository directories directly, with no
`apk update`:

```sh
printf '/root/repo/main\n/root/repo/community\n/root/repo/testing\n' > /etc/apk/repositories
apk upgrade
apk add htop
```

The file replaces the line for the PC's server from step 15, which the
board cannot reach without the cable.

### The newest packages from Pages, on the stick

Pages has what the last run built, also between releases. HOST, in any
directory, with the stick in the PC:

```sh
sudo mount LABEL=alpine-root /mnt
sudo rm -rf /mnt/root/repo
curl -fsSL https://naelolaiz.github.io/alpine-riscv32/files.txt | grep -e '/riscv32/' -e '\.rsa\.pub$' | sed 's|^|https://naelolaiz.github.io/alpine-riscv32/|' | sudo wget -q -x -nH --cut-dirs=1 -P /mnt/root/repo -i -
sudo sh -c 'cp /mnt/root/repo/*.rsa.pub /mnt/etc/apk/keys/'
sudo umount /mnt
```

- `rm -rf` first, because wget would save a second copy (`.1`) next to a
  file that is already there.
- `grep` keeps the riscv32 packages and the keys.
- `-x -nH --cut-dirs=1` keeps the path below the site (`main/riscv32/...`),
  the layout apk expects, so the board's `/etc/apk/repositories` from above
  stays the same.
- `sh -c`: `/mnt/root` is readable by root only, so the `*` must be
  expanded by a root shell, not by yours.

### Over the network (Wi-Fi, later)

BOARD, as root. The board needs a roughly correct clock to accept the
github.io certificate:

```sh
printf 'https://naelolaiz.github.io/alpine-riscv32/main\nhttps://naelolaiz.github.io/alpine-riscv32/community\nhttps://naelolaiz.github.io/alpine-riscv32/testing\n' > /etc/apk/repositories
apk update
apk upgrade
```

`apk update` downloads the three indexes; the keys are in `/etc/apk/keys`
already from the stick.

## Tested so far

A branch run without the secret (temporary key, built from scratch, run
37707841282 on 2026-10-08) passed both build jobs:

- `cross`: the whole bootstrap list plus mdev-conf in 1 h 32 min, after
  gmp moved to `ci/sources.txt`.
- `native`: every package in `ci/native-packages.txt`, ncurses to dropbear,
  in 1 h 38 min under qemu-user (dropbear alone 6 min).
- 234 files, 360 MB with the x86_64 cross compiler.

The first run on main (37824031688, 2026-10-09) built the same with the
secret's key (cross 71 min, native 2 h 48 min) and failed only at
`deploy-pages`, because Pages was not switched on.

After Pages was switched on, run 37824031688 was run again and deployed
the site. Branch run 38083237050 (2026-10-10) started from it: 233 files
in 5 seconds, every package of the cross job up to date (both
`bootstrap.sh` calls took 1 second), and the cross compiler went into the
cache (148 MB). Starting from Pages alone, it went on to build openssl and
the python3 chain again, which the first release already had; that is
why a run now adds the newest release on top.

Not tested yet:

- Adding the release on top of Pages, with the new indexes and the mixed
  keys: the next run, on this branch or on main, does that.
- Several native parts in a row, and a tag run with the `release` job.
- Installing from the site on the board.
- How long python3 takes on the runners: the first release has it, so no run
  builds it until its `pkgrel` changes. Its PGO build might not fit the
  native job's 6 hours together with other packages.

## Known limits

- `alpine:edge` changes every day; a future edge may no longer build the
  pinned aports commit, as it would on the PC.
- Old versions stay in the repository after a `pkgrel` bump; nothing prunes
  them yet (the first release has pcre2 r0 and r1). GitHub Pages allows 1 GB per
  site; the riscv32 repositories are about 0.5 GB now.
- A new signing key needs a full rebuild, and the workflow has no switch for
  that yet: the old packages would fail apk's signature check.
- Over HTTPS (Wi-Fi later), the board needs a roughly correct clock to accept
  the github.io certificate.
- Four native parts allow about 20 hours of native builds for a release.
  If that is not enough, there is no release; raising the number means
  adding a `native-5` job like the others.
