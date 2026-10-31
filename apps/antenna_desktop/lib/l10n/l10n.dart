// SPDX-License-Identifier: AGPL-3.0-only
// App strings (docs/DESIGN.md, "Languages"): app_en.arb (template, English) and app_ru.arb → gen-l10n → AppLocalizations.
// Widgets use `context.l.key`. lib/state and lib/host hold no strings: functions that need text take
// AppLocalizations as a parameter (no global state), and exceptions carry a reason code that the UI turns into text.

import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

extension L10nContext on BuildContext {
  /// Strings of the current app language.
  AppLocalizations get l => AppLocalizations.of(this);
}

/// Strings for a language code (`en`, `ru`), for tests and code outside the widget tree.
AppLocalizations l10nFor(String languageCode) => lookupAppLocalizations(Locale(languageCode));
