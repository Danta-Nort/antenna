#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Linux release files built outside GitHub Actions (D-81). Does what the `linux` job of .github/workflows/release.yml
# does, on a Linux x86_64 build machine, from a clean checkout of the tag:
#   core tests (fmt, clippy, all tests, a live `antenna mcp`); the window against the built antennad (analyze, widget
#   and live tests, golden images); antenna-<ver>-linux-<arch>.tar.gz and its install.sh check; the Linux window
#   antenna-desktop-<ver>-linux-<arch>.tar.gz and its check under Xvfb; from the same binaries, no new compilation,
#   the .deb packages (D-109, always) and the .rpm packages (best-effort: a spec+sources fallback when rpmbuild is
#   not installed here, packaging/linux/build-rpm.sh).
# Then it uploads the archives and packages to the release that the workflow's `publish` job created as a draft with
# the macOS files, makes the signed release manifest over all files of the release (antenna-<ver>-manifest.json and
# its .sig, signed with the release key; D-82, docs/UPDATES.md), regenerates SHA256SUMS.txt, and publishes it (a
# prerelease for versions with a "-"). Last, it mirrors the published release to the update host that the built-in
# update URL points at (D-137), when ANTENNA_UPDATE_MIRROR says how.
#
#   packaging/release-linux.sh [options] <tag>          e.g. packaging/release-linux.sh v0.1.0-preview.2
#     --no-upload      build and check only (a dry run): nothing is sent to GitHub
#     --publish-only   skip the build: upload the archives already in the output directory, then publish
#     --sign-only      no Linux files from here (the workflow built them, LINUX_ON_GITHUB): sign the draft's files, publish
#     --mirror-only    nothing built or changed on GitHub: check the published release's manifest, mirror it again
#     --ref REV        with --no-upload: build REV (a branch or commit) as if it were the tag; the version checks apply
#     --out DIR        output directory (default ~/.cache/antenna-release/<tag>); the log is release-linux.log there
#
# Environment: ANTENNA_RELEASE_KEY=<release key file> (required to upload: a release is published only with its signed
#   manifest); gh reads its usual GH_CONFIG_DIR / GH_TOKEN; GH_REPO=owner/name (default: from the `origin` remote);
#   CARGO (default ~/.cargo/bin/cargo, else cargo in PATH); FLUTTER (default flutter in PATH, else ~/flutter/bin/flutter;
#   must be the FLUTTER_VERSION pinned in release.yml); CARGO_BUILD_JOBS (default 8); NICE (default 10: the whole run is
#   niced, the build machine may be shared); BUILD_NUMBER (the Linux app's build number; default the +N of pubspec.yaml);
#   ANTENNA_UPDATE_MIRROR (a command that uploads the files it is given, in that order, to the update host, D-137;
#   unset: the mirror step only says it was skipped).
#
# The checkout is a temporary `git worktree` (mktemp -d) with its own target/; both are removed when the script exits,
# whatever the outcome. The script never builds in, or writes to, the working tree it is started from.
# If the draft release does not exist yet when the build is done, the script stops with the archives kept in the output
# directory: run it again with --publish-only once the workflow has created the draft.
# Requires: git, rustup (rust-toolchain.toml), protoc, cmake, clang, perl, ninja, pkg-config, GTK 3 headers, xvfb-run,
# python3, Flutter, dpkg-deb; gh for uploading. rpmbuild is optional (D-109: its absence does not fail the release).
# Missing system packages are reported, never installed.
set -euo pipefail

usage() { sed -n '3,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; }
die() { echo "release-linux: $*" >&2; exit 1; }

ARGS=("$@")
UPLOAD=1
BUILD=1
SIGN_ONLY=0
MIRROR_ONLY=0
REF=""
OUT=""
TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-upload) UPLOAD=0 ;;
    --publish-only) BUILD=0 ;;
    --sign-only) BUILD=0; SIGN_ONLY=1 ;;
    --mirror-only) BUILD=0; UPLOAD=0; MIRROR_ONLY=1 ;;
    --ref) REF="${2:?--ref needs a revision}"; shift ;;
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$TAG" ] || die "one tag only (got '$TAG' and '$1')"; TAG="$1" ;;
  esac
  shift
done
[ -n "$TAG" ] || { usage >&2; exit 2; }
case "$TAG" in v[0-9]*) ;; *) die "the tag looks like v0.1.0-preview.2, got '$TAG'" ;; esac
[ "$BUILD" = 1 ] || [ "$UPLOAD" = 1 ] || [ "$MIRROR_ONLY" = 1 ] || die "--publish-only with --no-upload would do nothing"
[ -z "$REF" ] || [ "$UPLOAD" = 0 ] || die "--ref is for dry runs: add --no-upload (a release is built from its tag only)"
[ -z "$REF" ] || [ "$BUILD" = 1 ] || die "--ref and --publish-only do not go together"

# Everything below runs niced, children included (cargo, rustc, flutter, the tests).
NICE="${NICE:-10}"
if [ -z "${_ANTENNA_RELEASE_NICED:-}" ] && [ "$NICE" != 0 ]; then
  export _ANTENNA_RELEASE_NICED=1
  exec nice -n "$NICE" "${BASH:-bash}" "$0" "${ARGS[@]}"
fi

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
VERSION="${TAG#v}"
ARCH="$(uname -m)"

# --- tools ----------------------------------------------------------------------------------------------------------
missing=()
need() { local t; for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done; }
need git sha256sum tar flock cmp
if [ "$UPLOAD" = 1 ] || [ "$MIRROR_ONLY" = 1 ]; then need gh; fi
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
[ -x "$CARGO" ] || CARGO="$(command -v cargo || true)"
if [ -z "$CARGO" ] || [ ! -x "$CARGO" ]; then missing+=("cargo (rustup)"); fi
if [ "$BUILD" = 1 ]; then
  FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}"
  [ -x "$FLUTTER" ] || missing+=("flutter (set FLUTTER=/path/to/flutter/bin/flutter)")
  need python3 perl protoc cmake clang clang++ ninja pkg-config xvfb-run dpkg-deb
  if command -v pkg-config >/dev/null && ! pkg-config --exists gtk+-3.0; then
    missing+=("GTK 3 headers (pkg-config gtk+-3.0)")
  fi
fi
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'release-linux: missing on this machine:\n' >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Install them first (on Ubuntu: protobuf-compiler cmake clang perl ninja-build pkg-config libgtk-3-dev xvfb," >&2
  echo "plus rustup, Flutter and gh); this script installs nothing." >&2
  exit 1
fi
REPO=""
check_remote_tag() {  # the tag on GitHub must be the one we build or built: the files carry its commit
  local local_ref remote_ref
  local_ref="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG")" \
    || die "tag $TAG not found in $REPO_ROOT (git fetch origin tag $TAG)"
  remote_ref="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq .object.sha)" || die "tag $TAG is not on GitHub ($REPO)"
  [ "$local_ref" = "$remote_ref" ] \
    || die "tag $TAG differs: here $local_ref, on GitHub $remote_ref (git fetch --force origin tag $TAG, then rebuild)"
}
if [ "$UPLOAD" = 1 ]; then
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (GH_CONFIG_DIR or GH_TOKEN)"
  # D-82: no release goes out without its signed manifest, so the key is checked before a long build.
  [ -n "${ANTENNA_RELEASE_KEY:-}" ] && [ -r "$ANTENNA_RELEASE_KEY" ] \
    || die "set ANTENNA_RELEASE_KEY to the release key file (docs/UPDATES.md §5): the release manifest is signed with it"
  REPO="${GH_REPO:-$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"
  case "$REPO" in */*) ;; *) die "cannot tell the GitHub repository (set GH_REPO=owner/name)" ;; esac
  check_remote_tag   # before a long build, not after it
elif [ "$MIRROR_ONLY" = 1 ]; then
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (GH_CONFIG_DIR or GH_TOKEN)"
  REPO="${GH_REPO:-$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')}"
  case "$REPO" in */*) ;; *) die "cannot tell the GitHub repository (set GH_REPO=owner/name)" ;; esac
fi

OUT="${OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/antenna-release/$TAG}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
# .deb is mandatory (dpkg-deb ships everywhere this script runs); .rpm is best-effort (D-109: rpmbuild is not
# always installed, and this script installs nothing) and is appended below once build() or the filesystem says it
# exists, so every later step that uploads, signs or lists "${LINUX_FILES[@]}" picks it up without its own copy of
# this logic.
LINUX_FILES=(
  "$OUT/antenna-$VERSION-linux-$ARCH.tar.gz"
  "$OUT/antenna-desktop-$VERSION-linux-$ARCH.tar.gz"
  "$OUT/antenna-$VERSION-linux-$ARCH.deb"
  "$OUT/antenna-desktop-$VERSION-linux-$ARCH.deb"
)
RPM_FILES=("$OUT/antenna-$VERSION-linux-$ARCH.rpm" "$OUT/antenna-desktop-$VERSION-linux-$ARCH.rpm")
add_rpm_files_if_present() {
  if [ -f "${RPM_FILES[0]}" ] && [ -f "${RPM_FILES[1]}" ]; then
    LINUX_FILES+=("${RPM_FILES[@]}")
  fi
}
MANIFEST="antenna-$VERSION-manifest.json"
TOOL="${ANTENNA_RELEASE_TOOL:-$OUT/tools/antenna-release}"
exec 9>"$OUT/.lock"
flock -n 9 || die "another release-linux.sh run for $TAG is using $OUT"
LOG="$OUT/release-linux.log"
# A later --mirror-only keeps the log of the run that published.
[ "$MIRROR_ONLY" = 0 ] || LOG="$OUT/release-linux-mirror.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
TEE_PID=$!

# --- timing and cleanup -------------------------------------------------------------------------------------------
T_START=$SECONDS
STEPS=()
CURRENT=""
WT=""
TMPS=()
fmt_dur() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
step() {  # step <title> <command…>: runs the command, records its duration
  local title="$1" t0=$SECONDS
  shift
  CURRENT="$title"
  echo
  echo "==> $title"
  "$@"
  STEPS+=("$(printf '%-76s %s' "$title" "$(fmt_dur $((SECONDS - t0)))")")
  CURRENT=""
}
cleanup() {
  local rc=$? s
  set +e
  cd "$REPO_ROOT"
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    echo
    echo "==> removing the temporary checkout $WT (its target/: $(du -sh "$WT/target" 2>/dev/null | cut -f1))"
    git -C "$REPO_ROOT" worktree remove --force "$WT"
  fi
  for s in "${TMPS[@]}"; do rm -rf "$s"; done
  # Only our own checkout's registration: a global `git worktree prune` also drops other people's worktrees that this
  # account cannot see (another user's home looks missing from here), which happened on a shared build server.
  if [ -n "$WT" ] && git -C "$REPO_ROOT" worktree list --porcelain | grep -qx "worktree $WT"; then
    git -C "$REPO_ROOT" worktree remove --force "$WT" 2>/dev/null || true
  fi
  echo
  echo "== release-linux $TAG: steps"
  for s in "${STEPS[@]}"; do echo "   $s"; done
  [ -z "$CURRENT" ] || echo "   FAILED: $CURRENT"
  echo "   total $(fmt_dur $((SECONDS - T_START))), exit code $rc; log: $LOG"
  exec >&- 2>&-
  wait "$TEE_PID"   # let tee write the last lines
  exit "$rc"
}
trap cleanup EXIT

echo "== release-linux $TAG (build=$BUILD upload=$UPLOAD sign_only=$SIGN_ONLY${REF:+ ref=$REF}) on $(uname -n), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "   output: $OUT"

# --- build and check ------------------------------------------------------------------------------------------------
build() {
  local rev work v fv have build_number f
  if [ -n "$REF" ]; then
    rev="$(git -C "$REPO_ROOT" rev-parse --verify "$REF^{commit}")" || die "no revision $REF"
  else
    rev="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG^{commit}")" \
      || die "tag $TAG not found in $REPO_ROOT (git fetch origin tag $TAG)"
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/antenna-release.XXXXXX")"
  TMPS+=("$work")
  WT="$work/src"
  step "Clean checkout of ${REF:-$TAG} ($(git -C "$REPO_ROOT" rev-parse --short=12 "$rev"))" \
    git -C "$REPO_ROOT" worktree add --detach "$WT" "$rev"
  cd "$WT"

  v="$(packaging/version.sh)"
  [ "$v" = "$VERSION" ] || die "tag $TAG does not match the version in Cargo.toml ($v): expected v$v"
  grep -q "^version: $v+" apps/antenna_desktop/pubspec.yaml || die "pubspec.yaml version ≠ $v"
  fv="$(sed -n "s/^ *FLUTTER_VERSION: *'\([^']*\)'.*/\1/p" .github/workflows/release.yml)"
  [ -n "$fv" ] || die "no FLUTTER_VERSION in .github/workflows/release.yml"
  have="$("$FLUTTER" --version --machine 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["frameworkVersion"])')" \
    || die "cannot run $FLUTTER --version"
  [ "$have" = "$fv" ] || die "Flutter $have at $FLUTTER, release.yml pins $fv: point FLUTTER at a $fv checkout"

  ANTENNA_COMMIT="$(git rev-parse --short=12 HEAD)"
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"
  CARGO_TARGET_DIR="$WT/target"   # the packaging scripts expect target/ inside the checkout
  CARGO_TERM_COLOR=never
  PATH="$(dirname "$CARGO"):$(dirname "$FLUTTER"):$PATH"
  export ANTENNA_COMMIT CARGO_BUILD_JOBS CARGO_TARGET_DIR CARGO_TERM_COLOR PATH
  build_number="${BUILD_NUMBER:-$(sed -n 's/^version: [^+]*+\([0-9]*\).*/\1/p' apps/antenna_desktop/pubspec.yaml)}"
  echo "   Antenna $VERSION ($ANTENNA_COMMIT), Flutter $have, $(rustc --version), jobs $CARGO_BUILD_JOBS, nice $(nice)"

  local f
  for f in "${LINUX_FILES[@]}" "${RPM_FILES[@]}"; do rm -f "$f" "$f.sha256"; done
  rm -rf "$OUT/rpm-sources"

  # The same commands as the `linux` job of release.yml: keep the two in step.
  step "Core: cargo fmt --check" cargo fmt --all --check
  step "Core: clippy -D warnings" cargo clippy --workspace --all-targets --locked -- -D warnings
  step "Core: no unwrap or panic outside tests (clippy --lib --bins)" \
    cargo clippy --workspace --lib --bins --locked -- -D clippy::unwrap_used -D clippy::panic
  step "Core: all tests" cargo test --workspace --locked
  step "Core: live antenna mcp (tools/mcp_smoke.py)" python3 tools/mcp_smoke.py target/debug
  cd "$WT/apps/antenna_desktop"
  step "Window: flutter pub get" flutter pub get
  step "Window: flutter analyze" flutter analyze
  # Live tests start real daemons and wait for delivery with timeouts; run in parallel on a busy machine they time out
  # (live_history "delivered: b2 after backup" under load average 7–8, 2026-10-03), so they run one file at a time.
  step "Window: widget, host and golden tests" flutter test --exclude-tags live
  step "Window: live tests against the built antennad (one at a time)" \
    env ANTENNAD_BIN="$WT/target/debug/antennad" flutter test --tags live --concurrency=1
  cd "$WT"
  # The golden tests above just confirmed docs/design/screens/ matches the window; copy what the guide needs from it
  # and check the guide against the window's own strings .
  step "Guide: screenshots from golden frames (tools/guide_shots.py)" python3 tools/guide_shots.py
  step "Guide: check (tools/guide_check.py)" python3 tools/guide_check.py
  step "Release tool antenna-release (signs the release manifest)" cargo build --release --locked -p antenna-release
  install -D -m 0755 target/release/antenna-release "$OUT/tools/antenna-release"
  # The local model runtime, built once for both archives (D-104).
  step "Local model runtime (llama.cpp llama-server, packaging/llama/build.sh)" \
    env LLAMA_JOBS="$CARGO_BUILD_JOBS" packaging/llama/build.sh "$work/runtime"
  export LLAMA_DIR="$work/runtime/llama"
  step "Archive antenna-$VERSION-linux-$ARCH.tar.gz" env VERSION="$VERSION" OUT="$OUT" packaging/linux/build-tarball.sh
  step "Check install.sh from the archive" packaging/linux/check-install.sh "${LINUX_FILES[0]}"
  step "Window for Linux antenna-desktop-$VERSION-linux-$ARCH.tar.gz" \
    env VERSION="$VERSION" OUT="$OUT" BUILD_NUMBER="$build_number" CORE_BIN_DIR="$WT/target/release" \
    packaging/linux/build-desktop.sh
  step "Check the window from the archive (ldd, menu entry, Xvfb, antenna:// link)" \
    packaging/linux/check-desktop.sh "${LINUX_FILES[1]}"
  step "Linux .deb packages from the same archives (packaging/linux/build-deb.sh, D-109)" \
    env VERSION="$VERSION" OUT="$OUT" ARCH="$ARCH" packaging/linux/build-deb.sh
  step "Check the .deb packages" packaging/linux/check-deb.sh "${LINUX_FILES[2]}" "${LINUX_FILES[3]}"
  # Best-effort: rpmbuild is not installed on every build machine (D-109); build-rpm.sh falls back to writing the
  # .spec files and their source payloads to $OUT/rpm-sources instead of failing the release over a missing tool.
  step "Linux .rpm packages from the same archives, best-effort (packaging/linux/build-rpm.sh, D-109)" \
    env VERSION="$VERSION" OUT="$OUT" ARCH="$ARCH" packaging/linux/build-rpm.sh
  step "Check the .rpm packages or their spec+sources fallback" \
    packaging/linux/check-rpm.sh "$OUT" "$VERSION" "$ARCH"
  add_rpm_files_if_present

  cd "$OUT"
  for f in "${LINUX_FILES[@]}"; do sha256sum -c "$(basename "$f").sha256"; done
}

# --- upload, checksums, publish -------------------------------------------------------------------------------------
# The antenna-release of the tag: left in $OUT/tools by the build; for --sign-only or --publish-only without it, built
# here from a temporary checkout of the tag.
release_tool() {
  local work
  [ -x "$TOOL" ] && return 0
  work="$(mktemp -d "${TMPDIR:-/tmp}/antenna-release-tool.XXXXXX")"
  TMPS+=("$work")
  WT="$work/src"
  step "Clean checkout of $TAG for antenna-release" git -C "$REPO_ROOT" worktree add --detach "$WT" "refs/tags/$TAG^{commit}"
  # From inside the checkout, so that rustup takes the tag's rust-toolchain.toml
  step "Release tool antenna-release" env -C "$WT" CARGO_TARGET_DIR="$WT/target" CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}" \
    "$CARGO" build --release --locked -p antenna-release
  install -D -m 0755 "$WT/target/release/antenna-release" "$TOOL"
}

publish() {
  local repo="$REPO" f draft assets dl commit flags

  if [ "$SIGN_ONLY" = 0 ]; then
    for f in "${LINUX_FILES[@]}"; do
      [ -f "$f" ] || die "missing $f: build it first (without --publish-only)"
      (cd "$OUT" && sha256sum -c --quiet "$(basename "$f").sha256") || die "$f does not match its .sha256"
    done
  fi

  check_remote_tag   # again: it may have moved during the build

  draft="$(gh release view "$TAG" -R "$repo" --json isDraft --jq .isDraft)" \
    || die "no release for $TAG yet; the archives are in $OUT. Once the release workflow has created the draft: $0 --publish-only $TAG"
  assets="$(gh release view "$TAG" -R "$repo" --json assets --jq '.assets[].name')"
  for f in "Antenna-$VERSION-macos-arm64.dmg" "antenna-$VERSION-macos-arm64-cli.tar.gz"; do
    grep -qxF "$f" <<<"$assets" || die "release $TAG has no $f: the macOS part is not done"
  done
  [ "$draft" = true ] || echo "   note: release $TAG is already published; the Linux files and SHA256SUMS.txt are replaced"

  if [ "$SIGN_ONLY" = 0 ]; then
    step "Upload the Linux archives" gh release upload "$TAG" -R "$repo" --clobber "${LINUX_FILES[@]}"
  fi

  # The release manifest and SHA256SUMS.txt over every file of the release, computed from what GitHub serves (and the
  # Linux files are compared with the local ones on the way)
  dl="$(mktemp -d "${TMPDIR:-/tmp}/antenna-release-assets.XXXXXX")"
  TMPS+=("$dl")
  step "Download all release files" gh release download "$TAG" -R "$repo" -D "$dl"
  rm -f "$dl/SHA256SUMS.txt" "$dl/$MANIFEST" "$dl/$MANIFEST.sig"
  if [ "$SIGN_ONLY" = 0 ]; then
    for f in "${LINUX_FILES[@]}"; do
      cmp -s "$f" "$dl/$(basename "$f")" || die "the uploaded $(basename "$f") differs from $f"
    done
  fi

  # D-82: the signed release manifest. `verify --pinned` uses the keys pinned in this very release: a release signed
  # with a key its own binaries do not trust is not published.
  commit="$(git -C "$REPO_ROOT" rev-parse --short=12 "refs/tags/$TAG^{commit}")"
  release_tool
  rm -f "$OUT/$MANIFEST" "$OUT/$MANIFEST.sig"
  # The local model catalog the tag's daemon was compiled with (D-104): copied into the manifest, checked equal.
  git -C "$REPO_ROOT" show "refs/tags/$TAG:packaging/models.json" > "$OUT/models.json"
  step "Release manifest over every file of the release" \
    "$TOOL" manifest --version "$VERSION" --commit "$commit" --models "$OUT/models.json" --out "$OUT/$MANIFEST" "$dl"
  step "Sign it with the release key" "$TOOL" sign --key "$ANTENNA_RELEASE_KEY" "$OUT/$MANIFEST"
  step "Check it with the keys pinned in $TAG" \
    "$TOOL" verify --pinned --all --models "$OUT/models.json" --dir "$dl" "$OUT/$MANIFEST"
  step "Upload the manifest and its signature" \
    gh release upload "$TAG" -R "$repo" --clobber "$OUT/$MANIFEST" "$OUT/$MANIFEST.sig"
  cp "$OUT/$MANIFEST" "$OUT/$MANIFEST.sig" "$dl/"
  (cd "$dl" && sha256sum -- * > "$OUT/SHA256SUMS.txt")
  cat "$OUT/SHA256SUMS.txt"
  step "Upload SHA256SUMS.txt" gh release upload "$TAG" -R "$repo" --clobber "$OUT/SHA256SUMS.txt"

  # The final notes (without the draft's "Linux files follow"), from the notes script of the tag itself
  git -C "$REPO_ROOT" show "refs/tags/$TAG:packaging/release-notes.sh" \
    | bash -s -- "$TAG" "$commit" "https://github.com/$repo" > "$OUT/notes.md"
  flags=(--draft=false --notes-file "$OUT/notes.md")
  case "$VERSION" in *-*) flags+=(--prerelease) ;; esac
  step "Publish the release" gh release edit "$TAG" -R "$repo" "${flags[@]}"
  gh release view "$TAG" -R "$repo" --json url,isDraft,isPrerelease,assets \
    --jq '{url, isDraft, isPrerelease, assets: [.assets[].name]}'
  cp "$OUT/SHA256SUMS.txt" "$dl/"
  mirror "$dl"
}

# D-137: the update host behind the built-in update URL. ANTENNA_UPDATE_MIRROR is the command that uploads the files
# it is given, in order. Every release file goes first, the channel manifest and its signature last, so the address
# never announces a release whose files are not there yet: antenna-preview-manifest.json for versions with a "-";
# a stable version goes to antenna-stable-manifest.json and to antenna-preview-manifest.json too, because preview
# installs follow every newer release (the installer fetches the release files next to it, docs/UPDATES.md §5.5).
mirror() {  # mirror <folder with every file of the published release, the signed manifest included>
  local dir="$1" ch channel c f files=() manifests=()
  if [ -z "${ANTENNA_UPDATE_MIRROR:-}" ]; then
    echo "   note: ANTENNA_UPDATE_MIRROR is not set: the update host still announces the previous release"
    echo "         (mirror this one later: $0 --mirror-only $TAG)"
    return 0
  fi
  [ -f "$dir/$MANIFEST" ] && [ -f "$dir/$MANIFEST.sig" ] || die "no signed manifest in $dir"
  case "$VERSION" in *-*) channel=preview ;; *) channel=stable ;; esac
  ch="$(mktemp -d "${TMPDIR:-/tmp}/antenna-release-channel.XXXXXX")"
  TMPS+=("$ch")
  for c in $([ "$channel" = stable ] && echo stable preview || echo preview); do
    cp "$dir/$MANIFEST" "$ch/antenna-$c-manifest.json"
    cp "$dir/$MANIFEST.sig" "$ch/antenna-$c-manifest.json.sig"
    manifests+=("$ch/antenna-$c-manifest.json" "$ch/antenna-$c-manifest.json.sig")
  done
  for f in "$dir"/*; do
    case "${f##*/}" in "$MANIFEST" | "$MANIFEST.sig") ;; *) files+=("$f") ;; esac
  done
  step "Mirror the release to the update host (the $channel channel)" \
    bash -c "$ANTENNA_UPDATE_MIRROR \"\$@\"" mirror "${files[@]}" "$dir/$MANIFEST" "$dir/$MANIFEST.sig" \
    "${manifests[@]}"
}

# --mirror-only: the published release as GitHub serves it, its manifest checked with the keys pinned in the tag first.
mirror_only() {
  local dl
  [ "$(gh release view "$TAG" -R "$REPO" --json isDraft --jq .isDraft)" = false ] \
    || die "release $TAG is not published yet: publish it first (the mirror only follows a published release)"
  dl="$(mktemp -d "${TMPDIR:-/tmp}/antenna-release-assets.XXXXXX")"
  TMPS+=("$dl")
  step "Download all release files" gh release download "$TAG" -R "$REPO" -D "$dl"
  release_tool
  git -C "$REPO_ROOT" show "refs/tags/$TAG:packaging/models.json" > "$OUT/models.json"
  step "Check the manifest with the keys pinned in $TAG" \
    "$TOOL" verify --pinned --all --models "$OUT/models.json" --dir "$dl" "$dl/$MANIFEST"
  mirror "$dl"
}

if [ "$MIRROR_ONLY" = 1 ]; then
  mirror_only
  exit 0
fi
if [ "$BUILD" = 1 ]; then build; fi
# --publish-only / --sign-only skip build(): pick up a .rpm pair left in $OUT by an earlier run that had rpmbuild.
add_rpm_files_if_present
if [ "$UPLOAD" = 1 ]; then
  publish
else
  echo
  echo "== dry run: nothing uploaded. These files would go to release $TAG:"
  (cd "$OUT" && sha256sum -- "${LINUX_FILES[@]##*/}")
fi
