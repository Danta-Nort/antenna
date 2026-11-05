# SPDX-License-Identifier: AGPL-3.0-only
# Shared staging for the .deb and .rpm packages (D-109, WP11): sourced by build-deb.sh and build-rpm.sh so the two
# package formats carry exactly the same files under /opt/antenna (D-111) and differ only in their own metadata
# (DEBIAN/control vs a .spec's %files) and build tool (dpkg-deb vs rpmbuild). Not meant to be run on its own.
#
# pkg_stage_cli_tree <cli-tarball> <root-dir> <id> builds, under <root-dir>:
#   opt/antenna/bin/{antennad,antenna,llama/… if the archive has it,.antenna-package}
#   usr/bin/{antenna,antennad}                  (symlinks to /opt/antenna/bin/…)
#   usr/lib/systemd/user/antennad.service        (fixed paths baked in, not install.sh's @…@ template)
#   usr/share/doc/antenna/copyright
# pkg_stage_desktop_tree <desktop-tarball> <root-dir> <id> builds, under <root-dir>:
#   opt/antenna/{antenna-desktop,lib/…,data/…}   (no bin/: this package Depends on antenna for antennad/antenna/llama)
#   usr/bin/antenna-desktop                      (symlink to /opt/antenna/antenna-desktop)
#   usr/share/applications/<id>.desktop, usr/share/icons/hicolor/256x256/apps/<id>.png
#   usr/share/doc/antenna-desktop/copyright
#
# Both need $ROOT (the repository root, for packaging/linux/antennad.service and LICENSE-AGPL-3.0) set by the caller.

pkg_stage_cli_tree() {
  local tgz="$1" root="$2" src
  src="$(mktemp -d "${TMPDIR:-/tmp}/antenna-pkg-cli-src.XXXXXX")"
  PKG_TMP_DIRS+=("$src")
  tar -C "$src" -xzf "$tgz"
  local pkg
  pkg="$(echo "$src"/antenna-*)"
  mkdir -p "$root/opt/antenna/bin" "$root/usr/bin" "$root/usr/lib/systemd/user" "$root/usr/share/doc/antenna"
  install -m 0755 "$pkg/bin/antennad" "$pkg/bin/antenna" "$root/opt/antenna/bin/"
  if [ -d "$pkg/bin/llama" ]; then
    cp -a "$pkg/bin/llama" "$root/opt/antenna/bin/llama"
  fi
  # `antenna_update::install::target::PACKAGE_MARKER`: without this file, a .deb/.rpm install is indistinguishable
  # from the install.sh layout (antennad next to antenna) and `antenna update` would fight the package manager over
  # the same files. Its presence is what matters, not its content (docs/UPDATES.md §5.2).
  cat > "$root/opt/antenna/bin/.antenna-package" <<'EOF'
This installation is managed by the system package manager (dpkg/apt or rpm/dnf): update it that way, not with
`antenna update` (which refuses, and says so: docs/UPDATES.md §5.2).
EOF
  chmod 0644 "$root/opt/antenna/bin/.antenna-package"
  ln -s /opt/antenna/bin/antenna "$root/usr/bin/antenna"
  ln -s /opt/antenna/bin/antennad "$root/usr/bin/antennad"
  # Only the [Unit]/[Service]/[Install] body is shared with install.sh's template: its header comment talks about
  # filling in placeholders at install time, which does not apply to a package (fixed paths, baked in at build time).
  {
    # REUSE-IgnoreStart
    echo "# SPDX-License-Identifier: AGPL-3.0-only"
    # REUSE-IgnoreEnd
    echo "# systemd --user service for the Antenna daemon, from the antenna .deb/.rpm package (D-109). Enable it"
    echo "# yourself: systemctl --user enable --now antennad. Logs: journalctl --user -u antennad"
    sed -n '/^\[Unit\]/,$p' "$ROOT/packaging/linux/antennad.service" \
      | sed -e "s#@ANTENNAD@#/opt/antenna/bin/antennad#" -e "s#@ARGS@#--relay n0#"
  } > "$root/usr/lib/systemd/user/antennad.service"
  chmod 0644 "$root/usr/lib/systemd/user/antennad.service"
  cp "$ROOT/LICENSE-AGPL-3.0" "$root/usr/share/doc/antenna/copyright"
}

pkg_stage_desktop_tree() {
  local tgz="$1" root="$2" id="$3" src
  src="$(mktemp -d "${TMPDIR:-/tmp}/antenna-pkg-desk-src.XXXXXX")"
  PKG_TMP_DIRS+=("$src")
  tar -C "$src" -xzf "$tgz"
  local pkg
  pkg="$(echo "$src"/antenna-desktop-*)"
  mkdir -p "$root/opt/antenna" "$root/usr/bin" "$root/usr/share/applications" \
    "$root/usr/share/icons/hicolor/256x256/apps" "$root/usr/share/doc/antenna-desktop"
  install -m 0755 "$pkg/antenna-desktop" "$root/opt/antenna/antenna-desktop"
  cp -a "$pkg/lib" "$root/opt/antenna/lib"
  cp -a "$pkg/data" "$root/opt/antenna/data"
  ln -s /opt/antenna/antenna-desktop "$root/usr/bin/antenna-desktop"
  sed "s|@EXEC@|/opt/antenna/antenna-desktop|" "$pkg/data/$id.desktop" \
    > "$root/usr/share/applications/$id.desktop"
  chmod 0644 "$root/usr/share/applications/$id.desktop"
  install -m 0644 "$pkg/data/app_icon.png" "$root/usr/share/icons/hicolor/256x256/apps/$id.png"
  cp "$ROOT/LICENSE-AGPL-3.0" "$root/usr/share/doc/antenna-desktop/copyright"
}

# Packages a binary needs, from its real dynamic dependencies (`ldd`), resolved to the Debian package owning each
# library (`dpkg -S` after `readlink -f`, since the database records the real path, not the multiarch symlink alias).
# Sorted, comma-joined ("a, b"); empty (not every library maps to a package, or dpkg-query is not installed) means
# no Depends line — still a valid, installable package, just a less precise one.
deb_depends_of() {
  local bin="$1" lib pkg
  command -v dpkg-query >/dev/null || return 0
  ldd "$bin" 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "=>") print $(i + 1)}' \
    | while read -r lib; do
        [ -f "$lib" ] || continue
        pkg="$(dpkg -S "$(readlink -f "$lib")" 2>/dev/null | head -1 | cut -d: -f1)"
        [ -n "$pkg" ] && echo "$pkg"
      done \
    | sort -u | paste -sd, - | sed 's/,/, /g'
}
