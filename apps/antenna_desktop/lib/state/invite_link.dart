// SPDX-License-Identifier: AGPL-3.0-only
// An invite link in any form it may reach a person in: `x://pair#…` (what nodes issue now), `antenna://pair#…` (the
// app scheme, opened by the system), `https://antenna.contact/#…` (the site's handler page: the fragment is either the
// full link or just its body). Parsing and signature checks are done by the daemon (antenna_proto::invite); here we
// only normalize to the form it accepts and tell a link apart from garbage.

const invitePrefix = 'x://pair#';
const inviteSchemePrefix = 'antenna://pair#';

/// The invite handler site (docs/SITE.md, "Invite link handler").
const _siteHosts = ['antenna.contact', 'www.antenna.contact'];

/// Link body: `<E_A>.<s>.<relay>[.<direct>]`, base32/base64url separated by dots, no whitespace.
final _body = RegExp(r'^[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}(\.[A-Za-z0-9_\-%:/.]+)*$');

/// Normalize a link to the form `antenna join` accepts; `null` means it is not an invite link.
String? normalizeInviteLink(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return null;
  // https://antenna.contact/#… (also without a scheme, with www, and with a trailing "/")
  final site = RegExp(r'^(?:https?://)?([^/#?]+)/?(?:\?[^#]*)?#(.+)$').firstMatch(s);
  if (site != null && _siteHosts.contains(site.group(1)!.toLowerCase())) {
    s = Uri.decodeComponent(site.group(2)!);
    if (_body.hasMatch(s)) return '$invitePrefix$s';
  }
  for (final p in const [invitePrefix, inviteSchemePrefix]) {
    if (s.toLowerCase().startsWith(p)) {
      final body = s.substring(p.length);
      return _body.hasMatch(body) ? '$p$body' : null;
    }
  }
  return null;
}

/// Looks like an invite link (for launch arguments and paste).
bool looksLikeInviteLink(String raw) => normalizeInviteLink(raw) != null;
