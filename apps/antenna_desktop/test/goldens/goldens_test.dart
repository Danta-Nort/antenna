// SPDX-License-Identifier: AGPL-3.0-only
// Golden screenshots of all screens (regression, DPR 1): test/goldens/*.png.
// Update: flutter test --update-goldens test/goldens/goldens_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'scenarios.dart';

void main() {
  shotDpr = 1.0;
  shotDir = '';
  defineScenarios();
  for (final e in scenarios.entries) {
    testWidgets(e.key, e.value);
  }
}
