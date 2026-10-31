// SPDX-License-Identifier: AGPL-3.0-only
//! Release versions: `MAJOR.MINOR.PATCH` with an optional pre-release (`0.1.0-preview.3`), ordered by the precedence
//! rules of Semantic Versioning 2.0 §11. Build metadata (`+…`) is rejected: two builds that differ only in metadata
//! would compare equal, and "strictly newer" must have one answer.

use std::{cmp::Ordering, fmt, str::FromStr};

/// A pre-release identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Ident {
    Num(u64),
    Alpha(String),
}

impl Ord for Ident {
    fn cmp(&self, other: &Self) -> Ordering {
        // SemVer §11.4: numeric identifiers compare numerically and have lower precedence than alphanumeric ones.
        match (self, other) {
            (Ident::Num(a), Ident::Num(b)) => a.cmp(b),
            (Ident::Num(_), Ident::Alpha(_)) => Ordering::Less,
            (Ident::Alpha(_), Ident::Num(_)) => Ordering::Greater,
            (Ident::Alpha(a), Ident::Alpha(b)) => a.cmp(b),
        }
    }
}

impl PartialOrd for Ident {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// A release version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
    pre: Vec<Ident>,
    text: String,
}

impl Version {
    /// Whether this is a pre-release (`0.1.0-preview.3`).
    pub fn is_prerelease(&self) -> bool {
        !self.pre.is_empty()
    }

    /// The numeric part (`0.1.0`), as macOS `CFBundleShortVersionString` carries it.
    pub fn numeric(&self) -> String {
        format!("{}.{}.{}", self.major, self.minor, self.patch)
    }
}

fn number(s: &str) -> Option<u64> {
    // SemVer §2 and §9: no leading zeros, digits only.
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) || (s.len() > 1 && s.starts_with('0'))
    {
        return None;
    }
    s.parse().ok()
}

/// A version that does not parse.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BadVersion(pub String);

impl fmt::Display for BadVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "bad version {:?} (expected MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-PRE)",
            self.0
        )
    }
}

impl std::error::Error for BadVersion {}

impl FromStr for Version {
    type Err = BadVersion;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || BadVersion(s.chars().take(64).collect());
        if s.len() > 64 || s.contains('+') {
            return Err(bad());
        }
        let (core, pre) = match s.split_once('-') {
            Some((c, p)) => (c, Some(p)),
            None => (s, None),
        };
        let mut parts = core.split('.');
        let (Some(a), Some(b), Some(c), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(bad());
        };
        let (major, minor, patch) = (
            number(a).ok_or_else(bad)?,
            number(b).ok_or_else(bad)?,
            number(c).ok_or_else(bad)?,
        );
        let mut idents = Vec::new();
        if let Some(pre) = pre {
            for id in pre.split('.') {
                if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
                    return Err(bad());
                }
                if id.bytes().all(|b| b.is_ascii_digit()) {
                    idents.push(Ident::Num(number(id).ok_or_else(bad)?));
                } else {
                    idents.push(Ident::Alpha(id.to_string()));
                }
            }
        }
        Ok(Self {
            major,
            minor,
            patch,
            pre: idents,
            text: s.to_string(),
        })
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch)
            .cmp(&(other.major, other.minor, other.patch))
            .then_with(|| match (self.pre.is_empty(), other.pre.is_empty()) {
                // SemVer §11.3: a pre-release has lower precedence than the release itself.
                (true, true) => Ordering::Equal,
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                // §11.4: identifier by identifier; a longer list wins when all shared ones are equal.
                (false, false) => self.pre.cmp(&other.pre),
            })
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    #[test]
    fn semver_precedence() {
        // The SemVer §11 example chain, plus our own release names.
        let chain = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ];
        for w in chain.windows(2) {
            assert!(v(w[0]) < v(w[1]), "{} < {}", w[0], w[1]);
        }
        assert!(v("0.1.0-preview.1") < v("0.1.0-preview.2"));
        assert!(v("0.1.0-preview.9") < v("0.1.0-preview.10"));
        assert!(v("0.1.0-preview.3") < v("0.1.0"));
        assert!(v("0.1.0") < v("0.1.1-preview.1"));
        assert!(v("0.9.9") < v("0.10.0"));
        assert_eq!(
            v("0.1.0-preview.2").cmp(&v("0.1.0-preview.2")),
            Ordering::Equal
        );
        assert_eq!(v("0.1.0-preview.2").numeric(), "0.1.0");
        assert!(v("0.1.0-preview.2").is_prerelease());
    }

    #[test]
    fn rejects_what_is_not_a_version() {
        for bad in [
            "",
            "1",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "1.02.3",
            "1.2.3-",
            "1.2.3-a..b",
            "1.2.3-01",
            "1.2.3+build",
            "1.2.3-a+b",
            "v1.2.3",
            "1.2.3-ä",
            " 1.2.3",
            "1.2.-3",
        ] {
            assert!(bad.parse::<Version>().is_err(), "{bad:?} must not parse");
        }
        assert_eq!(v("99.0.0-test.1").to_string(), "99.0.0-test.1");
    }
}
