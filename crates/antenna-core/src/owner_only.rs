// SPDX-License-Identifier: AGPL-3.0-only
//! Owner-only files and folders (SPEC §13): on unix every entry the daemon makes gets mode `0600` (a file) or `0700`
//! (a folder) when it is made. On Windows other users are kept out by the data folder's protected DACL, which every
//! entry under it inherits (D-134, WP-4, phase W1): nothing is set per entry there. The daemon does not start on
//! Windows until that DACL is set and checked, so no data is written under a weaker one.

use std::{
    fs::{DirBuilder, OpenOptions},
    io,
    path::Path,
};

/// `0600` for a file being opened, `0700` for a folder being made; on Windows nothing (the DACL is inherited).
pub(crate) trait OwnerOnly {
    /// Makes what is created owner-only.
    fn owner_only(&mut self) -> &mut Self;
}

impl OwnerOnly for OpenOptions {
    #[cfg(unix)]
    fn owner_only(&mut self) -> &mut Self {
        use std::os::unix::fs::OpenOptionsExt;
        self.mode(0o600)
    }

    #[cfg(windows)]
    fn owner_only(&mut self) -> &mut Self {
        self
    }
}

impl OwnerOnly for DirBuilder {
    #[cfg(unix)]
    fn owner_only(&mut self) -> &mut Self {
        use std::os::unix::fs::DirBuilderExt;
        self.mode(0o700)
    }

    #[cfg(windows)]
    fn owner_only(&mut self) -> &mut Self {
        self
    }
}

/// Makes an existing folder owner-only (`0700`); on Windows nothing (the DACL is inherited).
#[cfg(unix)]
pub(crate) fn owner_only_dir(p: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))
}

/// Makes an existing folder owner-only (`0700`); on Windows nothing (the DACL is inherited).
#[cfg(windows)]
pub(crate) fn owner_only_dir(_p: &Path) -> io::Result<()> {
    Ok(())
}

/// Makes an existing file owner-only (`0600`); on Windows nothing (the DACL is inherited).
#[cfg(unix)]
pub(crate) fn owner_only_file(p: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600))
}

/// Makes an existing file owner-only (`0600`); on Windows nothing (the DACL is inherited).
#[cfg(windows)]
pub(crate) fn owner_only_file(_p: &Path) -> io::Result<()> {
    Ok(())
}
