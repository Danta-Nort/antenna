// SPDX-License-Identifier: AGPL-3.0-only
// Representations of the verification code (SAS), as in crates/antenna-proto/src/sas.rs (Q-6): there is one code,
// 6 digits; the emoji are another representation of the same digits (one animal per digit). The daemon does the
// comparison; the UI only displays and accepts input.

/// Digit → emoji (the `antenna_proto::sas::EMOJI` table). Animal names for reading aloud are in the window's language
/// (lib/l10n, keys sasAnimal0…9; the daemon accepts them in both English and Russian).
final class SasGlyph {
  const SasGlyph(this.digit, this.emoji);
  final int digit;
  final String emoji;
}

const sasGlyphs = <SasGlyph>[
  SasGlyph(0, '\u{1F436}'), // dog
  SasGlyph(1, '\u{1F431}'), // cat
  SasGlyph(2, '\u{1F981}'), // lion
  SasGlyph(3, '\u{1F40E}'), // horse
  SasGlyph(4, '\u{1F984}'), // unicorn
  SasGlyph(5, '\u{1F437}'), // pig
  SasGlyph(6, '\u{1F418}'), // elephant
  SasGlyph(7, '\u{1F430}'), // rabbit
  SasGlyph(8, '\u{1F43C}'), // panda
  SasGlyph(9, '\u{1F413}'), // rooster
];

/// Code length.
const sasLength = 6;

/// Glyphs of a 6-digit code; `null` if it is not digits.
List<SasGlyph>? sasGlyphsOf(String digits) {
  if (digits.length != sasLength || !RegExp(r'^\d{6}$').hasMatch(digits)) return null;
  return [for (final c in digits.codeUnits) sasGlyphs[c - 0x30]];
}

/// Glyphs of any digit string (the history fingerprint is 3 digits, PROTOCOL §16); `null` if it is not digits.
List<SasGlyph>? digitGlyphs(String digits) {
  if (digits.isEmpty || !RegExp(r'^\d+$').hasMatch(digits)) return null;
  return [for (final c in digits.codeUnits) sasGlyphs[c - 0x30]];
}
