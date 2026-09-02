# AGENTS.md

Termux package build recipes for Android. Each package is a directory containing a `build.sh` that exports `TERMUX_PKG_*` variables (and optionally `termux_step_*` function overrides). This is a recipe repo, not an app default project — most work is editing `build.sh` + patches, not writing code.

## Repo layout / ownership

- `packages/` — main repo (termux-main)
- `root-packages/` — root repo (termux-root) in `repo.json`
- `x11-packages/` — X11/GUI repo (termux-x11)
- `disabled-packages/` — disabled recipes, **not built / not linted**
- `sample/` — skeleton `build.sh` for new packages
- `scripts/bin/` — helper tools (run as `./scripts/bin/<tool>`)
- glibc/library packages (`TERMUX_PACKAGE_LIBRARY=glibc`) are **not** in this repo; they live in the separate `termux/glibc-packages` repo. `repo.json` defines which dirs map to which apt repos.

## Key commands

- Lint a package (required before PR):
  `./scripts/lint-packages.sh packages/<name>/build.sh`
  Lint everything: `./scripts/lint-packages.sh` (lints all repos from `repo.json`)
- Bump revision (rebuild, no version change):
  `./scripts/bin/revbump <package> [package...]`
  Also bump all dependents: `./scripts/bin/revbump --dependencies <package>`
- Update checksum for a bumped version: `./scripts/bin/update-checksum <package>`
- Build a package: `./build-package.sh [-a ARCH] [--library bionic|glibc] [-i] <packages/<name>>`
  (default arch `aarch64`, deps install in `-s` mode; `-i` installs build deps). Builds need the Termux Docker image / SDK setup — see `scripts/setup-termux.sh` / `run-docker.sh`.

## build.sh conventions (lint enforces these)

- **Tabs for indentation** (spaces only for array alignment); its own `check_indentation` in lint.
- No executable bit on `build.sh` (lint fails if set).
- Required fields: `TERMUX_PKG_HOMEPAGE`, `_DESCRIPTION`, `_LICENSE`, `_MAINTAINER`, `_VERSION`, `_SRCURL`, `_SHA256`.
- `TERMUX_PKG_LICENSE`: SPDX identifier, or `custom`/`non-free`; comma-separated. Only whitelisted ids pass lint.
- `_DESCRIPTION` ≤ 100 chars.
- `_VERSION` must start with a digit, only `. - +` allowed (`:` for epoch). Never use git hash/branch for version; use commit **date** (`YYYY.MM.DD`) instead.
- `_SRCURL` should reference `${TERMUX_PKG_VERSION}` (bash slicing ok), never hardcode; use official source bundles. `git+https:` / `git+file:` protocols allowed. `TERMUX_PKG_SHA256` may be `SKIP_CHECKSUM` or omitted for `git+`/`TERMUX_PKG_SKIP_SRC_EXTRACT=true`.
- `TERMUX_PKG_DEPENDS` = runtime deps only; `TERMUX_PKG_BUILD_DEPENDS` = build-time only. Don't list common build tools (autoconf, clang, ndk-sysroot, etc.) in deps.
- Rebuild without version change → set/increment `TERMUX_PKG_REVISION` (placed right below `_VERSION`). When `_VERSION` bumps, **remove** `_REVISION`. Downgrades/changed scheme → bump epoch `N:`.

## Patches

- Unified diff (`git diff` or `diff -uNr`). One logical change per patch; self-descriptive filenames.
- Patches are preprocessed: use `@TERMUX_PREFIX@` (→ `/data/data/com.termux/files/usr`) and `@TERMUX_HOME@` instead of hardcoding paths.
- Termux has **no FHS paths** (`/bin`, `/usr`, `/etc`, `/var`, `/run`, `/sbin`...). Replace them with prefixed equivalents (`/run`,`/sbin` → `@TERMUX_PREFIX@/var/run`, `@TERMUX_PREFIX@/bin`). Unprefixed hardcoded FHS paths are a common bug reviewers reject.

## Other gotchas

- Prefix is `/data/data/com.termux/files/usr`; home is `/data/data/com.termux/files/home`. This repo is a fork whose internal package name is `dev.apexstudio.ide` (see `scripts/properties.sh`); don't change forked identity vars.
- `TERMUX_PKG_BUILD_IN_SRC=true` for in-tree/Makefile-only builds. `TERMUX_PKG_PLATFORM_INDEPENDENT=true` for arch-independent.
- A `*` Latin: recipes support `TERMUX_PKG_VERSION` as an array and `*.subpackage.sh` subpackages (split debs) — subpackage name must also pass `dpkg --validate-pkgname`.
- Lint runs a version-increment check comparing against `origin/master`. Commit trailer `%ci:no-build` makes lint skip the version check and tells CI to skip the build/stale-file checks (used when only running tests or doing non-package CI changes).

## Commit messages

Use `type(repo/pkg): summary` — types: `addpkg`, `bump`, `fix`, `dwnpkg`, `disable`, `enhance`, `chore`, `rebuild`, `scripts(path)`, `ci(action)`. `<repo>` ∈ {main, root, x11}. Lines ≤ 80 chars. Add `Closes #N` / `Co-authored-by:` when merging others' PRs.
