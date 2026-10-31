// SPDX-License-Identifier: AGPL-3.0-only
// Goldens for Touch ID (D-102, experimental): Settings → Security with the line on and its "?" open (when the password
// is asked next), the enrollment dialog, the approval cards in the conversation with "Approve with Touch ID" (one
// request, and "Approve all from this agent" for two), and the locked gate with "Unlock with Touch ID" above the
// password. A daemon that speaks x-control/7 and a fake Secure Enclave; a Mac's window.

part of 'scenarios.dart';

Future<AppModel> _touchModel({DaemonState state = DaemonState.unlocked, List<ApprovalInfo>? approvals, bool on = true}) async {
  final d = FakeDaemon(contacts: demoContacts(), history: demoHistory(), approvals: approvals, state: state)
    ..protoVersion = 7
    ..receipts = {jordan.linkId: demoReceipts()};
  d.ownerKeys.passwordDueMs = ms(DateTime(2026, 10, 16, 9, 30));
  final h = FakeTouchId();
  if (on) h.preset(h.dirFor(d.socketPath), d.ownerKeys);
  final m = AppModel(
    connector: (_) => d,
    socketPath: d.socketPath,
    live: false,
    clock: () => fixedNow,
    binaries: _bins,
    updater: FakeCli().updater(cliPath: _bins.cli!),
    defaultSocket: d.socketPath,
    touchId: h,
  );
  await m.connect();
  // The gate as after "Lock keys": the sheet at app start (D-131) would leave the frame at once.
  m.touchIdAtStart = false;
  return m;
}

Future<void> _touchSecurity(WidgetTester t) async {
  await t.tap(find.byKey(const Key('nav-settings')));
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(const Key('settings-security')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void _defineTouchIdScenarios() {
  Future<void> settings(WidgetTester t, String name, {bool dark = false}) async {
    final m = await _touchModel();
    await _frame(t, dark ? _dark(m) : XApp(model: m));
    await _touchSecurity(t);
    await t.tap(find.byKey(const Key('help-touchid')));
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  }

  _s('56_touch_id_settings', (t) => settings(t, '56_touch_id_settings'));
  _s('56_touch_id_settings_dark', (t) => settings(t, '56_touch_id_settings_dark', dark: true));

  Future<void> enroll(WidgetTester t, String name, {bool dark = false}) async {
    final m = await _touchModel(on: false);
    await _frame(t, dark ? _dark(m) : XApp(model: m));
    await _touchSecurity(t);
    await t.tap(find.byKey(const Key('touchid-switch')));
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('owner-password')), 'correct horse battery');
    await t.pump(const Duration(milliseconds: 400));
    await _snap(t, name);
  }

  _s('57_touch_id_enroll', (t) => enroll(t, '57_touch_id_enroll'));
  _s('57_touch_id_enroll_dark', (t) => enroll(t, '57_touch_id_enroll_dark', dark: true));

  Future<void> approval(WidgetTester t, String name, {bool dark = false}) async {
    final m = await _touchModel(approvals: [demoChatApproval(), demoChatSend()]);
    await _frame(t, dark ? _dark(m) : XApp(model: m));
    await _snap(t, name);
  }

  _s('58_approval_touch_id', (t) => approval(t, '58_approval_touch_id'));
  _s('58_approval_touch_id_dark', (t) => approval(t, '58_approval_touch_id_dark', dark: true));

  Future<void> unlock(WidgetTester t, String name, {bool dark = false}) async {
    final m = await _touchModel(state: DaemonState.locked);
    await _frame(t, dark ? _dark(m) : XApp(model: m));
    await _snap(t, name);
  }

  _s('59_unlock_touch_id', (t) => unlock(t, '59_unlock_touch_id'));
  _s('59_unlock_touch_id_dark', (t) => unlock(t, '59_unlock_touch_id_dark', dark: true));
}
