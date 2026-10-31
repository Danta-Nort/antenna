// SPDX-License-Identifier: AGPL-3.0-only
// Formatting of times and identifiers for monospace display. Dates are in the window's language: the pattern comes
// from the ARB (`datePattern`: en `MMM d, yyyy` → Oct 2, 2026; ru `dd.MM.yyyy` → 02.10.2026) via intl DateFormat;
// times use the 24-hour clock in both languages (`14:07`).

import 'dart:async';

import 'package:intl/date_symbol_data_local.dart' show initializeDateFormatting;
import 'package:intl/intl.dart' show DateFormat;

import '../l10n/app_localizations.dart';

String _two(int n) => n.toString().padLeft(2, '0');

bool _dateData = false;

/// intl month names: data for all locales comes from the package itself, synchronously (the Future returned by
/// initializeDateFormatting is a formality). Outside the widget tree nothing else would load it (in the window,
/// GlobalMaterialLocalizations does).
void _ensureDateData() {
  if (_dateData) return;
  unawaited(initializeDateFormatting());
  _dateData = true;
}

/// `14:07`.
String hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// `02.10.2026` (ru) / `Oct 2, 2026` (en).
String formatDate(AppLocalizations l, DateTime t) {
  _ensureDateData();
  return DateFormat(l.datePattern, l.localeName).format(t);
}

/// Date and time: `02.10.2026 14:07` / `Oct 2, 2026 14:07`.
String formatDateTime(AppLocalizations l, DateTime t) => '${formatDate(l, t)} ${hhmm(t)}';

/// Timestamp for the chat list: today `14:07`, yesterday the localized `Yesterday`, otherwise `02.10` / `Oct 2`.
String shortStamp(AppLocalizations l, DateTime t, DateTime now) {
  final d0 = DateTime(now.year, now.month, now.day);
  final d = DateTime(t.year, t.month, t.day);
  final diff = d0.difference(d).inDays;
  if (diff == 0) return hhmm(t);
  if (diff == 1) return l.dateYesterdayShort;
  _ensureDateData();
  return DateFormat(l.dateShortPattern, l.localeName).format(t);
}

/// Day divider in a chat.
String dayLabel(AppLocalizations l, DateTime t, DateTime now) {
  final d0 = DateTime(now.year, now.month, now.day);
  final d = DateTime(t.year, t.month, t.day);
  final diff = d0.difference(d).inDays;
  if (diff == 0) return l.dateToday(formatDate(l, t));
  if (diff == 1) return l.dateYesterday(formatDate(l, t));
  return formatDate(l, t);
}

/// Short hex: `3f9a…c21e`.
String shortHex(String hex, {int head = 4, int tail = 4}) {
  if (hex.length <= head + tail + 1) return hex;
  return '${hex.substring(0, head)}…${hex.substring(hex.length - tail)}';
}

/// Groups of 4 characters for displaying keys: `3f9a 1c0e …`.
String groupHex(String hex, {int group = 4, int max = 32}) {
  final h = hex.length > max ? hex.substring(0, max) : hex;
  final parts = <String>[];
  for (var i = 0; i < h.length; i += group) {
    parts.add(h.substring(i, i + group > h.length ? h.length : i + group));
  }
  return parts.join(' ') + (hex.length > max ? ' …' : '');
}

/// Remaining time `09:41` (mm:ss) or `1:02:05`.
/// The time left of a request in words, never a bare `08:35` that reads as a clock: "Expires in 8 min", "Expires in
/// 1 h 5 min", "Expires in 35 s", "Expired". Whole minutes are counted down (8:35 is 8 min).
String expiresIn(AppLocalizations l, Duration d) {
  if (d.inSeconds <= 0) return l.approvalsExpiredShort;
  final h = d.inHours, m = d.inMinutes % 60;
  final time = h > 0
      ? l.durationHoursMinutes(h, m)
      : d.inMinutes > 0
          ? l.durationMinutes(d.inMinutes)
          : l.durationSeconds(d.inSeconds);
  return l.approvalsExpiresIn(time);
}

String countdown(Duration d) {
  if (d.isNegative) return '00:00';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

/// Parses a CLI duration: `10m`, `90s`, `2h`, `1h30m`. `null` if it cannot be parsed.
Duration? parseDuration(String s) {
  final re = RegExp(r'(\d+)\s*(h|m|s|ms)');
  final str = s.trim();
  if (str.isEmpty) return null;
  var total = Duration.zero;
  var consumed = 0;
  for (final m in re.allMatches(str)) {
    final n = int.parse(m.group(1)!);
    total += switch (m.group(2)) {
      'h' => Duration(hours: n),
      'm' => Duration(minutes: n),
      's' => Duration(seconds: n),
      _ => Duration(milliseconds: n),
    };
    consumed += m.group(0)!.replaceAll(' ', '').length;
  }
  if (consumed != str.replaceAll(' ', '').length) return null;
  return total;
}
