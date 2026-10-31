// SPDX-License-Identifier: AGPL-3.0-only
// Access to AppModel from the widget tree (no third-party state packages).

import 'package:flutter/widgets.dart';

import '../state/app_model.dart';

class AppScope extends InheritedNotifier<AppModel> {
  const AppScope({super.key, required AppModel model, required super.child}) : super(notifier: model);

  static AppModel of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(s != null, 'AppScope is missing');
    return s!.notifier!;
  }

  static AppModel? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;

  /// Without subscribing to changes (for tap handlers).
  static AppModel read(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<AppScope>();
    assert(s != null, 'AppScope is missing');
    return s!.notifier!;
  }
}
