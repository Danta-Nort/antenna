// SPDX-License-Identifier: Apache-2.0
//! Protocol version. It is part of the pairing transcript hash (SPEC §6 item 6): there are no legacy modes and
//! downgrade is impossible: a node with a different version simply does not pair.

use serde::{Deserialize, Serialize};

/// Version of the `antenna` wire protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProtocolVersion(pub u16);

impl ProtocolVersion {
    /// Draft version of stage 0 / MVP slices 1–2: unsigned messages (`auth = null`).
    pub const V0: ProtocolVersion = ProtocolVersion(0);
    /// Link format v1 (slice 3): message signatures, author counter, history verification, receipts, rekey
    /// (`docs/PROTOCOL.md` §12, §16–§17). Not compatible with v0 nodes: `RoutingBlob.v` differs.
    pub const V1: ProtocolVersion = ProtocolVersion(1);
    /// Current version of this build.
    pub const CURRENT: ProtocolVersion = Self::V1;
}

impl std::fmt::Display for ProtocolVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "x/{}", self.0)
    }
}
