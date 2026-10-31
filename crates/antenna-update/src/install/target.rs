// SPDX-License-Identifier: AGPL-3.0-only
//! Which installation this `antenna` belongs to, from the path of the running binary.
//!
//! - macOS: `<…>/Antenna.app/Contents/Helpers/antenna` → the app bundle (the `.dmg` asset, kind `app`);
//! - `bin/antenna` with `antennad` next to it → the `install.sh` layout on Linux, or the unpacked macOS CLI archive
//!   (the `.tar.gz` asset, kind `cli`);
//! - anything else cannot update itself: a development build in `target/`, the Linux window bundle (its `bin/` sits
//!   next to `antenna-desktop`), an app running from the disk image or from a translocated copy, a `.deb`/`.rpm`
//!   install (D-109: `/opt/antenna/bin`, marked with [`PACKAGE_MARKER`] so the files dpkg/rpm track are never
//!   touched by `antenna update` — the package manager updates those).

use std::path::{Path, PathBuf};

use crate::manifest::Platform;

/// Next to `antennad` and `antenna`: present only in the files `packaging/linux/build-deb.sh` and `build-rpm.sh`
/// stage into the `.deb`/`.rpm` (D-109), never in the `install.sh` archive. Its presence, not its content, is what
/// matters: a plain, deterministic marker beats asking `dpkg`/`rpm` (not always installed, and querying them is a
/// subprocess call for a fact a build-time file answers for free).
pub const PACKAGE_MARKER: &str = ".antenna-package";

/// The installation to update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// macOS app bundle.
    MacosApp {
        /// `…/Antenna.app`.
        app: PathBuf,
    },
    /// `antenna` and `antennad` in one directory.
    BinDir {
        /// The directory.
        dir: PathBuf,
    },
    /// Cannot update itself.
    Unsupported {
        /// Why, for the owner.
        reason: String,
        /// The path that was looked at.
        path: Option<PathBuf>,
    },
}

impl Target {
    /// Detects the installation from the canonical path of the running `antenna` binary. `os` is
    /// `std::env::consts::OS`; `is_file` is injectable for tests.
    pub fn detect(exe: &Path, os: &str, is_file: &dyn Fn(&Path) -> bool) -> Target {
        let unsupported = |reason: String| Target::Unsupported {
            reason,
            path: Some(exe.to_path_buf()),
        };
        // The Windows installer and its updates are not built yet (D-134, WP-28, WP-29, phase W4).
        if os == "windows" {
            return unsupported(
                "antenna update does not support Windows yet: install the new release by hand"
                    .into(),
            );
        }
        let Some(dir) = exe.parent() else {
            return unsupported("cannot tell where this antenna is installed".into());
        };
        if os == "macos"
            && dir.file_name().is_some_and(|n| n == "Helpers")
            && let Some(contents) = dir.parent()
            && contents.file_name().is_some_and(|n| n == "Contents")
            && let Some(app) = contents.parent()
            && app.extension().is_some_and(|e| e == "app")
        {
            let s = app.to_string_lossy();
            if s.contains("/AppTranslocation/") {
                return unsupported(
                    "Antenna runs from a temporary copy that macOS made (App Translocation): move Antenna.app to \
                     Applications, open it from there, then update"
                        .into(),
                );
            }
            if s.starts_with("/Volumes/") {
                return unsupported(
                    "Antenna runs from the disk image: drag it to Applications, open it from there, then update".into(),
                );
            }
            return Target::MacosApp {
                app: app.to_path_buf(),
            };
        }
        if !is_file(&dir.join("antennad")) {
            return unsupported(format!(
                "{} has no antennad next to antenna: not an installation antenna update knows",
                dir.display()
            ));
        }
        if is_file(&dir.join(PACKAGE_MARKER)) {
            return unsupported(
                "this Antenna was installed from a .deb or .rpm package: update it with your package manager \
                 (apt/dpkg or dnf/rpm), not antenna update"
                    .into(),
            );
        }
        if dir.file_name().is_some_and(|n| n == "bin")
            && let Some(top) = dir.parent()
            && is_file(&top.join("antenna-desktop"))
        {
            return unsupported(
                "this is the Linux window bundle: unpack the new antenna-desktop archive in its place (self-update \
                 covers the install.sh layout only)"
                    .into(),
            );
        }
        if dir.components().any(|c| c.as_os_str() == "target")
            && (dir.ends_with("debug") || dir.ends_with("release"))
        {
            return unsupported(format!(
                "{} is a development build: install a release (install.sh) to use antenna update",
                dir.display()
            ));
        }
        Target::BinDir {
            dir: dir.to_path_buf(),
        }
    }

    /// The installation kind for JSON: `macos_app`, `bin_dir`, `unsupported`.
    pub fn kind(&self) -> &'static str {
        match self {
            Target::MacosApp { .. } => "macos_app",
            Target::BinDir { .. } => "bin_dir",
            Target::Unsupported { .. } => "unsupported",
        }
    }

    /// The path that gets replaced.
    pub fn path(&self) -> Option<&Path> {
        match self {
            Target::MacosApp { app } => Some(app),
            Target::BinDir { dir } => Some(dir),
            Target::Unsupported { path, .. } => path.as_deref(),
        }
    }

    /// Which release asset fits this installation.
    pub fn platform(&self) -> Option<Platform> {
        match self {
            Target::MacosApp { .. } => Some(Platform::this("app")),
            Target::BinDir { .. } => Some(Platform::this("cli")),
            Target::Unsupported { .. } => None,
        }
    }

    /// Where the installer keeps its staging folder, journal and lock: next to what it replaces, on the same file
    /// system (an atomic swap needs that).
    pub fn base(&self) -> Option<PathBuf> {
        match self {
            Target::MacosApp { app } => app.parent().map(Path::to_path_buf),
            Target::BinDir { dir } => Some(dir.clone()),
            Target::Unsupported { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(list: &'static [&'static str]) -> impl Fn(&Path) -> bool {
        move |p: &Path| list.iter().any(|f| Path::new(f) == p)
    }

    #[test]
    fn macos_app() {
        let t = Target::detect(
            Path::new("/Applications/Antenna.app/Contents/Helpers/antenna"),
            "macos",
            &files(&[]),
        );
        assert_eq!(
            t,
            Target::MacosApp {
                app: "/Applications/Antenna.app".into()
            }
        );
        assert_eq!(t.base().unwrap(), Path::new("/Applications"));
        assert_eq!(t.platform().unwrap().kind, "app");
        // A copy in the home folder works too.
        assert!(matches!(
            Target::detect(
                Path::new("/Users/a/Apps/Antenna.app/Contents/Helpers/antenna"),
                "macos",
                &files(&[])
            ),
            Target::MacosApp { .. }
        ));
        for bad in [
            "/private/var/folders/x/T/AppTranslocation/1234/d/Antenna.app/Contents/Helpers/antenna",
            "/Volumes/Antenna 0.1.0-preview.2/Antenna.app/Contents/Helpers/antenna",
        ] {
            assert_eq!(
                Target::detect(Path::new(bad), "macos", &files(&[])).kind(),
                "unsupported",
                "{bad}"
            );
        }
        // The same path on Linux is not an app bundle.
        assert_eq!(
            Target::detect(
                Path::new("/Applications/Antenna.app/Contents/Helpers/antenna"),
                "linux",
                &files(&[])
            )
            .kind(),
            "unsupported"
        );
    }

    #[test]
    fn windows_cannot_update_itself_yet() {
        // Even a layout that would be an installation elsewhere.
        let t = Target::detect(
            Path::new("C:/Users/a/AppData/Local/Programs/Antenna/antenna.exe"),
            "windows",
            &|_| true,
        );
        assert_eq!(t.kind(), "unsupported");
        assert!(t.base().is_none() && t.platform().is_none());
    }

    #[test]
    fn bin_dir_and_the_rest() {
        let t = Target::detect(
            Path::new("/home/a/.local/bin/antenna"),
            "linux",
            &files(&["/home/a/.local/bin/antennad"]),
        );
        assert_eq!(
            t,
            Target::BinDir {
                dir: "/home/a/.local/bin".into()
            }
        );
        assert_eq!(t.platform().unwrap().kind, "cli");
        // The macOS CLI archive unpacked into ~/.local/bin is the same layout.
        assert_eq!(
            Target::detect(
                Path::new("/Users/a/.local/bin/antenna"),
                "macos",
                &files(&["/Users/a/.local/bin/antennad"])
            )
            .kind(),
            "bin_dir"
        );
        // No daemon next to it.
        assert_eq!(
            Target::detect(Path::new("/usr/bin/antenna"), "linux", &files(&[])).kind(),
            "unsupported"
        );
        // The Linux window bundle.
        let t = Target::detect(
            Path::new("/opt/antenna-desktop/bin/antenna"),
            "linux",
            &files(&[
                "/opt/antenna-desktop/bin/antennad",
                "/opt/antenna-desktop/antenna-desktop",
            ]),
        );
        assert!(
            matches!(&t, Target::Unsupported { reason, .. } if reason.contains("window bundle"))
        );
        // A development build.
        let t = Target::detect(
            Path::new("/src/antenna/target/debug/antenna"),
            "linux",
            &files(&["/src/antenna/target/debug/antennad"]),
        );
        assert!(
            matches!(&t, Target::Unsupported { reason, .. } if reason.contains("development build"))
        );
        assert_eq!(t.base(), None);
    }

    /// D-109: a `.deb`/`.rpm` install looks exactly like the `install.sh` layout (`antennad` next to `antenna`), so
    /// without the marker file it would be mistaken for one and `antenna update` would fight the package manager
    /// over the same files (reverting the `is_file(&dir.join(PACKAGE_MARKER))` check above makes this test see
    /// `bin_dir` instead and fail here: the negative control).
    #[test]
    fn a_package_install_cannot_update_itself() {
        let t = Target::detect(
            Path::new("/opt/antenna/bin/antenna"),
            "linux",
            &files(&[
                "/opt/antenna/bin/antennad",
                "/opt/antenna/bin/.antenna-package",
            ]),
        );
        assert!(
            matches!(&t, Target::Unsupported { reason, .. } if reason.contains("package manager")),
            "{t:?}"
        );
        assert_eq!(t.platform(), None);
        // Without the marker, the very same directory is the ordinary bin_dir layout: the marker is what changes
        // the answer, not something else about this path.
        assert_eq!(
            Target::detect(
                Path::new("/opt/antenna/bin/antenna"),
                "linux",
                &files(&["/opt/antenna/bin/antennad"])
            )
            .kind(),
            "bin_dir"
        );
    }
}
