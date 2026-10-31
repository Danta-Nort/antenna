// SPDX-License-Identifier: AGPL-3.0-only
// The Settings section: the owner's picture, app theme and language, daemon, the antenna terminal command, updates, keys. Minimal (reference
// v3): each setting is one line, its name, a small "?" with the longer explanation, and the control.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../host/updater.dart';
import '../../l10n/l10n.dart';
import '../../state/appearance.dart';
import '../../state/messages.dart';
import '../../theme/x_theme.dart';
import '../../version.dart';
import '../app.dart';
import '../app_scope.dart';
import '../cli/cli_dialog.dart';
import '../code/agents_detected.dart' show RolePresetCard;
import '../home/home_screen.dart';
import '../pictures/profile_card.dart';
import '../security/owner_confirm.dart';
import '../updates/auto_update_card.dart';
import '../updates/ready_banner.dart';
import '../updates/update_dialog.dart';
import '../widgets/badges.dart';
import '../widgets/dialog_shell.dart';
import '../widgets/popover.dart';
import '../widgets/section_page.dart';
import 'check_panel.dart';
import 'touch_id_card.dart';

/// "Local network (no internet)": LAN via mDNS (CONTROL §18). Turning it on needs the owner password; state and
/// discovered links come from `lan_status`, with a plain explanation of the privacy trade-off (DECISIONS D-77).
class LanCard extends StatefulWidget {
  const LanCard({super.key});

  @override
  State<LanCard> createState() => _LanCardState();
}

class _LanCardState extends State<LanCard> {
  final _auth = OwnerAuthController();
  bool _asking = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.read(context).refreshLan();
    });
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  Future<void> _set(bool enabled) async {
    final m = AppScope.read(context);
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await m.setLan(
        enabled: enabled, auth: enabled ? _auth.auth(m, touchIdConfirmReason(l, l.lanEnable)) : null);
    _auth.password.clear();
    if (!mounted) return;
    final fellBack = _auth.fellBack(l, m, err);
    setState(() {
      _busy = false;
      _asking = err != null && enabled;
      _error = err == null || fellBack ? null : describeError(l, err);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context);
    final l = context.l;
    final lan = m.lan;
    final on = lan?.enabled ?? false;
    final found = lan?.links.where((x) => x.found.isNotEmpty).toList() ?? const [];
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingRow(
          id: 'lan',
          title: l.lanTitle,
          help: l.lanAbout,
          helpExtra: Text(l.lanPrivacy, style: XText.meta.copyWith(color: XColors.textDim)),
          control: Switch(
            key: const Key('lan-switch'),
            value: on || _asking,
            onChanged: _busy
                ? null
                : (v) {
                    if (v) {
                      setState(() => _asking = true);
                    } else {
                      setState(() => _asking = false);
                      if (on) _set(false);
                    }
                  },
          ),
        ),
        if (_asking && !on) ...[
          // Turning it on: the privacy trade-off is shown where the owner decides (D-77), not only behind the "?".
          const SizedBox(height: 12),
          _PrivacyNote(l.lanPrivacy),
          const SizedBox(height: 12),
          OwnerAuthField(controller: _auth, autofocus: true, onSubmitted: (_) => _set(true)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('lan-enable'),
              onPressed: _busy ? null : () => _set(true),
              child: Text(l.lanEnable),
            ),
          ),
        ],
        if (_error != null) ErrorLine(_error!),
        if (lan != null && on) ...[
          const SizedBox(height: 12),
          Row(children: [
            Icon(lan.listening ? Icons.wifi_tethering : Icons.portable_wifi_off_outlined,
                size: 16, color: lan.listening ? XColors.ok : XColors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                lan.listening ? l.lanListening : l.lanNotListening(lan.error ?? ''),
                style: XText.body.copyWith(color: lan.listening ? XColors.ok : XColors.warn),
              ),
            ),
            TextButton(onPressed: m.refreshLan, child: Text(l.filesRefresh)),
          ]),
          const SizedBox(height: 8),
          if (lan.links.isEmpty)
            Text(l.lanNoLinks, style: XText.meta)
          else
            for (final x in lan.links)
              Padding(
                key: Key('lan-link-${x.contact}'),
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  SizedBox(width: 180, child: Text(x.contact, style: XText.body)),
                  Expanded(
                    child: Text(
                      x.found.isNotEmpty
                          ? l.lanFound(x.found.join(', '))
                          : (x.beacon ? l.lanBeacon : l.lanNotFound),
                      style: XText.meta.copyWith(color: x.found.isNotEmpty ? XColors.ok : XColors.textMute),
                    ),
                  ),
                ]),
              ),
          if (found.isEmpty && lan.links.isNotEmpty) Text(l.lanNoneFound, style: XText.meta),
        ],
      ]),
    );
  }
}

/// The LAN privacy trade-off, shown while the owner turns the local network on.
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('lan-privacy'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: XColors.bg2, borderRadius: BorderRadius.circular(XRadius.m)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.privacy_tip_outlined, size: 16, color: XColors.textDim),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: XText.meta.copyWith(color: XColors.textDim, height: 16 / 11))),
        ]),
      );
}

/// One setting on one line (reference v3, minimal settings): its name, a small "?" with the longer explanation (on
/// hover, a click or keyboard focus), and the control on the right.
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.id,
    required this.title,
    required this.help,
    required this.control,
    this.helpExtra,
    this.titleTag,
  });

  /// Names the "?" `help-<id>` (tests).
  final String id;
  final String title;
  final String help;
  final Widget? helpExtra;
  final Widget control;

  /// A small tag after the name (the Experimental tag, D-94).
  final Widget? titleTag;

  @override
  Widget build(BuildContext context) => Row(children: [
        Flexible(child: Text(title, style: XText.title)),
        if (titleTag != null) ...[const SizedBox(width: 8), titleTag!],
        const SizedBox(width: 8),
        HelpHint(help, id: id, label: context.l.settingsMoreAbout(title), extra: helpExtra),
        const Spacer(),
        const SizedBox(width: 16),
        control,
      ]);
}

/// "Updates": the version of this window and, from `antenna update --json`, what is installed, where, and with which
/// release key; installing from files; checking online only when the CLI has an update URL. The CLI verifies
/// everything; the card shows what it says.
class UpdatesCard extends StatefulWidget {
  const UpdatesCard({super.key});

  @override
  State<UpdatesCard> createState() => _UpdatesCardState();
}

class _UpdatesCardState extends State<UpdatesCard> {
  UpdateStatus? _status;
  Object? _statusError;
  bool _checking = false;
  UpdateVerification? _check;
  Object? _checkError;

  AntennaUpdater? get _updater => AppScope.read(context).updater;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStatus());
  }

  Future<void> _loadStatus() async {
    final u = mounted ? _updater : null;
    if (u == null) return;
    try {
      final s = await u.status();
      if (mounted) setState(() => _status = s);
    } on Object catch (e) {
      if (mounted) setState(() => _statusError = e);
    }
  }

  Future<void> _runCheck() async {
    final u = _updater;
    if (u == null) return;
    setState(() {
      _checking = true;
      _check = null;
      _checkError = null;
    });
    try {
      final v = await u.check();
      if (mounted) setState(() => _check = v);
    } on Object catch (e) {
      if (mounted) setState(() => _checkError = e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final u = _updater;
    final s = _status;
    final canInstall = u != null && s != null && s.install.supported;
    return SectionCard(
      key: const Key('updates-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(l.updateTitle, style: XText.title),
          const SizedBox(width: 8),
          HelpHint(l.updateAbout, id: 'updates', label: l.settingsMoreAbout(l.updateTitle)),
        ]),
        const SizedBox(height: 12),
        // A release that can be installed now, wherever its files are (D-UI-29).
        const UpdateReadyBanner(),
        FactRow(l.updateFactWindow, appVersionLine),
        if (u == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l.updateNoCli, key: const Key('updates-no-cli'), style: XText.bodyDim),
          )
        else if (s != null)
          ..._statusFacts(l, s)
        else if (_statusError == null)
          FactRow(l.updateFactInstalled, l.updateLoading),
        if (_statusError case final e?) ErrorLine(describeUpdateError(l, e), detail: updateErrorDetail(e)),
        if (u != null) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  key: const Key('update-pick-manifest'),
                  leadingIcon: const Icon(Icons.description_outlined, size: 16),
                  onPressed: () => pickAndVerifyUpdate(context, folder: false),
                  child: Text(l.updateChooseManifest),
                ),
                MenuItemButton(
                  key: const Key('update-pick-folder'),
                  leadingIcon: const Icon(Icons.folder_open_outlined, size: 16),
                  onPressed: () => pickAndVerifyUpdate(context, folder: true),
                  child: Text(l.updateChooseFolder),
                ),
              ],
              builder: (context, menu, _) => OutlinedButton.icon(
                key: const Key('update-from-file'),
                onPressed: canInstall ? () => (menu.isOpen ? menu.close() : menu.open()) : null,
                icon: const Icon(Icons.system_update_alt_rounded, size: 16),
                label: Text(l.updateFromFile),
              ),
            ),
            if (s?.updateUrl != null)
              OutlinedButton.icon(
                key: const Key('update-check'),
                onPressed: _checking ? null : _runCheck,
                icon: const Icon(Icons.travel_explore_rounded, size: 16),
                label: Text(_checking ? l.updateChecking : l.updateCheck),
              ),
          ]),
        ],
        if (_check case final v?) _CheckResult(v),
        if (_checkError case final e?) ErrorLine(describeUpdateError(l, e), detail: updateErrorDetail(e)),
        // The daemon's own setting (x-control/7): it does not need the CLI.
        const AutoUpdateSetting(),
      ]),
    );
  }

  List<Widget> _statusFacts(AppLocalizations l, UpdateStatus s) {
    final keys = s.keys;
    final keyId = keys.ids.isEmpty ? '?' : shortKeyId(keys.ids.first);
    return [
      FactRow(l.updateFactInstalled, s.current.label),
      if (s.install.supported && s.install.path != null) FactRow(l.updateFactLocation, s.install.path!),
      FactRow(
        l.updateFactKey,
        keys.pinned == 0 ? l.updateKeyNone : (keys.testKey ? l.updateKeyTest(keyId) : l.updateKeyPinned(keyId)),
        valueColor: keys.pinned == 0 || keys.testKey ? XColors.warn : null,
      ),
      if (s.previous case final p?) FactRow(l.updateFactPrevious, p.label),
      if (!s.install.supported)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            l.updateUnsupported(s.install.reason ?? ''),
            key: const Key('updates-unsupported'),
            style: XText.bodyDim.copyWith(color: XColors.warn),
          ),
        ),
    ];
  }
}

/// The result of "Check for updates": up to date, or a newer signed release and where to download it.
class _CheckResult extends StatelessWidget {
  const _CheckResult(this.v);
  final UpdateVerification v;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (!v.signature.valid) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(l.updateNotSigned, style: XText.bodyDim.copyWith(color: XColors.danger)),
      );
    }
    if (!v.newer) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          l.updateUpToDate(v.current.version),
          key: const Key('update-up-to-date'),
          style: XText.bodyDim.copyWith(color: XColors.ok),
        ),
      );
    }
    final (sig, sigColor) = signatureLook(l, v.signature);
    final url = v.asset?.url;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.updateAvailable(v.release.version), key: const Key('update-available'), style: XText.title),
        const SizedBox(height: 8),
        FactRow(l.updateFactSignature, sig, valueColor: sigColor),
        if (v.asset case final a?) FactRow(l.updateFactFile, a.name),
        if (url != null)
          Row(children: [
            Expanded(child: SelectableText(url, style: XText.monoSmall)),
            IconButton(
              tooltip: l.commonCopy,
              onPressed: () => Clipboard.setData(ClipboardData(text: url)),
              icon: const Icon(Icons.copy_rounded, size: 15),
            ),
          ]),
        const SizedBox(height: 4),
        Text(l.updateDownloadHint, style: XText.meta),
      ]),
    );
  }
}

/// The parts of Settings, listed on the left.
enum SettingsSection { profile, general, interface, network, security, agents, check, advanced }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initialSection = SettingsSection.profile, this.onOpenAgents});
  final SettingsSection initialSection;

  /// Settings → Agents → "Open Agents" (the home screen switches the section).
  final VoidCallback? onOpenAgents;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsSection _section = widget.initialSection;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 32, 40, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.navSettings, style: XText.h1),
            const SizedBox(height: 24),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 196,
                  child: Column(children: [
                    for (final s in SettingsSection.values)
                      _SectionItem(s, selected: s == _section, onTap: () => setState(() => _section = s)),
                  ]),
                ),
                const SizedBox(width: 28),
                Expanded(
                  child: ListView(
                    key: ValueKey(_section),
                    padding: const EdgeInsets.only(bottom: 32),
                    children: _cards(context),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _cards(BuildContext context) {
    final m = AppScope.of(context);
    final look = AppearanceScope.maybeOf(context);
    final l = context.l;
    final segmentStyle = SegmentedButton.styleFrom(
      textStyle: XText.label,
      side: BorderSide(color: XColors.lineStrong),
      selectedBackgroundColor: XColors.accentSoft,
      selectedForegroundColor: XColors.accent,
      foregroundColor: XColors.textDim,
    );
    return switch (_section) {
      SettingsSection.profile => [const ProfilePictureCard()],
      SettingsSection.general => [
          if (look != null)
            SectionCard(
              child: SettingRow(
                id: 'appearance',
                title: l.settingsAppearance,
                help: l.settingsAppearanceHint,
                control: SegmentedButton<ThemeChoice>(
                  showSelectedIcon: false,
                  style: segmentStyle,
                  segments: [
                    ButtonSegment(value: ThemeChoice.system, label: Text(l.settingsSystem, key: const Key('theme-system'))),
                    ButtonSegment(value: ThemeChoice.light, label: Text(l.settingsThemeLight, key: const Key('theme-light'))),
                    ButtonSegment(value: ThemeChoice.dark, label: Text(l.settingsThemeDark, key: const Key('theme-dark'))),
                  ],
                  selected: {look.choice},
                  onSelectionChanged: (s) => look.choice = s.first,
                ),
              ),
            ),
          if (look != null)
            SectionCard(
              child: SettingRow(
                id: 'language',
                title: l.settingsLanguage,
                help: l.settingsLanguageHint,
                // Each language is named in itself, so it can be recognized even when the current UI language
                // cannot be read.
                control: SegmentedButton<LangChoice>(
                  showSelectedIcon: false,
                  style: segmentStyle,
                  segments: [
                    ButtonSegment(value: LangChoice.system, label: Text(l.settingsSystem, key: const Key('lang-system'))),
                    ButtonSegment(value: LangChoice.en, label: Text(l10nFor('en').langEnglish, key: const Key('lang-en'))),
                    ButtonSegment(value: LangChoice.ru, label: Text(l10nFor('ru').langRussian, key: const Key('lang-ru'))),
                  ],
                  selected: {look.lang},
                  onSelectionChanged: (s) => look.lang = s.first,
                ),
              ),
            ),
        ],
      SettingsSection.interface => [
          if (look != null)
            SectionCard(
              key: const Key('interface-card'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SettingRow(
                  id: 'interface',
                  title: l.settingsInterface,
                  help: l.settingsInterfaceHint,
                  control: SegmentedButton<InterfaceMode>(
                    showSelectedIcon: false,
                    style: segmentStyle,
                    segments: [
                      ButtonSegment(value: InterfaceMode.chat, label: Text(l.settingsInterfaceChat, key: const Key('ui-chat'))),
                      ButtonSegment(
                        value: InterfaceMode.code,
                        enabled: !m.codeComing,
                        label: Text(l.settingsInterfaceCode, key: const Key('ui-code')),
                      ),
                    ],
                    selected: {m.codeComing ? InterfaceMode.chat : look.ui},
                    onSelectionChanged: (s) => look.ui = s.first,
                  ),
                ),
                // Windows: Code mode is not built there yet (D-134); said in plain sight, not behind the "?".
                if (m.codeComing) ...[
                  const SizedBox(height: 8),
                  Text(l.settingsInterfaceCodeComing, key: const Key('ui-code-coming'), style: XText.bodyDim),
                ],
              ]),
            ),
        ],
      SettingsSection.network => [
          if (m.lanSupported)
            const LanCard()
          else
            SectionCard(child: Text(l.settingsNetworkNone, style: XText.bodyDim)),
        ],
      SettingsSection.security => [
          const TouchIdCard(),
          SectionCard(
            child: SettingRow(
              id: 'keys',
              title: l.settingsKeys,
              help: l.settingsKeysHint,
              control: OutlinedButton.icon(
                onPressed: m.lock,
                icon: const Icon(Icons.lock_outline, size: 16),
                label: Text(l.commonLockKeys),
              ),
            ),
          ),
        ],
      SettingsSection.agents => [
          const RolePresetCard(),
          SectionCard(
            child: SettingRow(
              id: 'agents',
              title: l.navAgents,
              help: l.settingsAgentsHint,
              control: widget.onOpenAgents == null
                  ? const SizedBox.shrink()
                  : OutlinedButton(
                      key: const Key('settings-open-agents'),
                      onPressed: widget.onOpenAgents,
                      child: Text(l.settingsAgentsOpen),
                    ),
            ),
          ),
        ],
      SettingsSection.check => [
          const SectionCard(child: CheckPanel()),
        ],
      SettingsSection.advanced => [
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text('Daemon', style: XText.title),
                const SizedBox(width: 8),
                HelpHint(l.daemonStopNote, id: 'daemon', label: l.settingsMoreAbout('Daemon')),
              ]),
              const SizedBox(height: 8),
              const DaemonFacts(note: false),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (m.host != null) OutlinedButton(onPressed: m.stopDaemon, child: Text(l.commonStopDaemon)),
                OutlinedButton.icon(
                  key: const Key('cli-button'),
                  onPressed: () => showCliDialog(context),
                  icon: const Icon(Icons.terminal, size: 16),
                  label: Text(l.commonCliCommand),
                ),
              ]),
            ]),
          ),
          const UpdatesCard(),
        ],
    };
  }
}

/// One entry of the section list on the left.
class _SectionItem extends StatelessWidget {
  const _SectionItem(this.section, {required this.selected, required this.onTap});
  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final (icon, label) = switch (section) {
      SettingsSection.profile => (Icons.account_circle_outlined, l.settingsSectionProfile),
      SettingsSection.general => (Icons.tune_rounded, l.settingsSectionGeneral),
      SettingsSection.interface => (Icons.view_quilt_outlined, l.settingsSectionInterface),
      SettingsSection.network => (Icons.wifi_rounded, l.settingsSectionNetwork),
      SettingsSection.security => (Icons.shield_outlined, l.settingsSectionSecurity),
      SettingsSection.agents => (Icons.smart_toy_outlined, l.settingsSectionAgents),
      SettingsSection.check => (Icons.fact_check_outlined, l.settingsSectionCheck),
      SettingsSection.advanced => (Icons.settings_outlined, l.settingsSectionAdvanced),
    };
    final fg = selected ? XColors.accent : XColors.textDim;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('settings-${section.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(XRadius.m),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? XColors.accentSoft : null,
              borderRadius: BorderRadius.circular(XRadius.m),
            ),
            child: Row(children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: XText.body.copyWith(color: selected ? XColors.accent : XColors.text, fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
