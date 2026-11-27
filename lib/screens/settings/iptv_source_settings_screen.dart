import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart' show verifyPin;
import '../../providers/multi_server_provider.dart';
import '../../services/iptv/iptv_client.dart';
import '../../services/iptv/iptv_parental.dart';
import '../../services/iptv/iptv_store.dart';
import '../../services/iptv/iptv_sync_service.dart';
import '../../services/iptv/iptv_sync_worker.dart';
import '../../services/iptv/xtream_api.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import 'package:intl/intl.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';
import '../profile/pin_entry_dialog.dart';
import 'add_iptv_screen.dart';
import 'iptv_channel_editor_screen.dart';
import 'iptv_group_editor_screen.dart';

/// Everything about one IPTV source: its status (account and last refreshes),
/// refresh now, and every setting — name, refresh intervals, user-agent and
/// referrer, Xtream output format and Live TV only, guide addresses and time
/// shift, guide window, numbering, groups (hide, order, lock) and channels
/// (hide, rename, renumber, guide mapping).
///
/// Changes are saved at once (the connection row through the registry, the
/// group and channel changes in the IPTV database) and the live client adopts
/// them. Rows are list tiles, so touch and the D-pad work alike.
class IptvSourceSettingsScreen extends StatefulWidget {
  const IptvSourceSettingsScreen({super.key, required this.connection, this.store, this.syncService});

  final IptvConnection connection;

  /// Test seams.
  @visibleForTesting
  final IptvStore? store;
  @visibleForTesting
  final IptvSyncService? syncService;

  @override
  State<IptvSourceSettingsScreen> createState() => _IptvSourceSettingsScreenState();
}

class _IptvSourceSettingsScreenState extends State<IptvSourceSettingsScreen> {
  late IptvConnection _connection = widget.connection;
  XtreamAccount? _account;
  int _channelCount = 0;
  int _programmeCount = 0;

  IptvStore get _store => widget.store ?? IptvStore.instance;
  IptvSyncService get _sync => widget.syncService ?? IptvSyncService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStats());
  }

  Map<String, Object?>? _guideState;
  int _guideFromProvider = 0;

  static String _ago(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 1) return t.iptv.guideJustNow;
    if (d.inHours < 1) return t.iptv.guideMinutesAgo(n: d.inMinutes);
    if (d.inDays < 1) return t.iptv.guideHoursAgo(n: d.inHours);
    return t.iptv.guideDaysAgo(n: d.inDays);
  }

  /// The guide's state in plain words: where it comes from, how many
  /// programmes, when it was read, and whether the Xtream login's own guide
  /// failed (then each channel's guide is read from the provider).
  String _guideLine(IptvConnection c, IptvSyncRecord record) {
    final own = _guideState?['own'];
    final reason = _guideState?['error'];
    final String origin;
    if (c.isXtream && c.useSourceEpg && (own == 'ok' || own == null)) {
      origin = t.iptv.guideFromXtream;
    } else if (!c.isXtream && c.useSourceEpg && own == 'ok') {
      origin = t.iptv.guideFromPlaylist;
    } else if (c.epgUrls.isNotEmpty) {
      origin = t.iptv.guideFromAddresses;
    } else if (c.isXtream && c.useSourceEpg) {
      origin = t.iptv.guideFromXtream;
    } else {
      origin = t.iptv.guideNoAddress;
    }
    final parts = <String>[
      origin,
      t.iptv.guideProgrammes(count: NumberFormat.decimalPattern().format(_programmeCount)),
      if (_guideFromProvider > 0) t.iptv.guideFromProvider(count: _guideFromProvider),
      if (record.lastSuccess != null) t.iptv.guideUpdated(when: _ago(record.lastSuccess!)) else t.iptv.neverRefreshed,
    ];
    final line = parts.join(' · ');
    if (c.isXtream && c.useSourceEpg && own == 'failed') {
      return '$line\n${t.iptv.guideXtreamFailed(reason: reason is String ? reason : '-')}';
    }
    if (c.isXtream && c.useSourceEpg && own == 'empty') return '$line\n${t.iptv.guideXtreamEmpty}';
    final error = record.error;
    if (error != null && error != IptvSyncService.interruptedError) return '$line\n${t.iptv.lastError(error: error)}';
    return line;
  }

  Future<void> _loadStats() async {
    try {
      final channels = await _store.channelCount(_connection.id);
      final programmes = await _store.programmeCount(_connection.id);
      final client = _client();
      final account = client == null ? null : await client.storedAccount();
      final rawGuide = await _store.meta(_connection.id, IptvMetaKeys.guideState);
      final fromProvider = await _store.guideFetchedCount(_connection.id);
      Map<String, Object?>? guideState;
      try {
        final decoded = rawGuide == null ? null : jsonDecode(rawGuide);
        if (decoded is Map) guideState = decoded.cast<String, Object?>();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _channelCount = channels;
        _programmeCount = programmes;
        _account = account;
        _guideState = guideState;
        _guideFromProvider = fromProvider;
      });
    } catch (e) {
      appLogger.d('[iptv] source stats unreadable (${e.runtimeType})');
    }
  }

  IptvClient? _client() {
    try {
      return context.read<MultiServerProvider>().serverManager.iptvClient(_connection.id);
    } catch (_) {
      return null;
    }
  }

  /// Save [updated]: the row, the live client, and a refresh when what is
  /// read changed.
  Future<void> _save(IptvConnection updated, {bool refreshPlaylist = false, bool refreshGuide = false}) async {
    setState(() => _connection = updated);
    try {
      await context.read<ConnectionRegistry>().upsert(updated);
    } catch (e) {
      appLogger.w('[iptv] source settings not saved (${e.runtimeType})');
      if (mounted) showErrorSnackBar(context, t.iptv.saveFailed);
      return;
    }
    if (!mounted) return;
    _client()?.updateConnection(updated);
    _sync.update(updated);
    IptvDataRevision.bump(updated.id);
    if (refreshPlaylist || refreshGuide) {
      unawaited(_refresh(playlist: refreshPlaylist, guide: refreshGuide || refreshPlaylist));
    }
  }

  Future<void> _refresh({required bool playlist, required bool guide}) async {
    await _sync.refresh(_connection.id, connection: _connection, playlist: playlist, epg: guide);
    await _loadStats();
  }

  // ---- editors ---------------------------------------------------------------

  Future<void> _editText({
    required String title,
    required String label,
    required String? value,
    required void Function(String text) apply,
    bool allowEmpty = true,
    bool multiline = false,
    bool obscure = false,
    TextInputType? keyboard,
  }) async {
    final text = await showTextInputDialog(
      context,
      title: title,
      labelText: label,
      initialValue: value,
      allowEmpty: allowEmpty,
      multiline: multiline,
      obscureText: obscure,
      keyboardType: keyboard,
    );
    if (text == null || !mounted) return;
    apply(text.trim());
  }

  Future<void> _pickHours({required String title, required int value, required void Function(int hours) apply}) async {
    const options = [3, 6, 12, 24, 48, 168];
    final picked = await showOptionPickerDialog<int>(
      context,
      title: title,
      options: [
        for (final h in options)
          (icon: h == value ? Symbols.check_rounded : null, label: t.iptv.everyHours(hours: h), value: h),
      ],
    );
    if (picked != null && mounted) apply(picked);
  }

  Future<void> _pickDays({
    required String title,
    required int value,
    required int max,
    required void Function(int) apply,
  }) async {
    final picked = await showOptionPickerDialog<int>(
      context,
      title: title,
      options: [
        for (var d = title == t.iptv.guideFutureDays ? 1 : 0; d <= max; d++)
          (icon: d == value ? Symbols.check_rounded : null, label: t.iptv.daysCount(count: d), value: d),
      ],
    );
    if (picked != null && mounted) apply(picked);
  }

  Future<void> _pickShift() async {
    final options = [for (var m = -12 * 60; m <= 12 * 60; m += 30) m];
    final picked = await showOptionPickerDialog<int>(
      context,
      title: t.iptv.guideShift,
      options: [
        for (final m in options)
          (
            icon: m == _connection.epgShiftMinutes ? Symbols.check_rounded : null,
            label: formatShiftMinutes(m),
            value: m,
          ),
      ],
    );
    if (picked != null && mounted) unawaited(_save(_connection.copyWith(epgShiftMinutes: picked)));
  }

  Future<void> _unlockParental() async {
    final profile = context.read<ActiveProfileProvider>().active;
    final hash = profile?.pinHash;
    if (hash != null && hash.isNotEmpty) {
      String? error;
      while (mounted) {
        final pin = await showPinEntryDialog(context, profile!.displayName, errorMessage: error);
        if (pin == null) return;
        if (verifyPin(pin, hash)) break;
        error = t.iptv.wrongPin;
      }
    } else {
      final ok = await showConfirmDialog(
        context,
        title: t.iptv.showLockedGroups,
        message: t.iptv.showLockedGroupsNoPin,
        confirmText: t.iptv.show,
      );
      if (!ok) return;
    }
    IptvParentalGate.unlock(_connection.id);
    if (mounted) setState(() {});
  }

  Future<void> _remove() async {
    final ok = await showDeleteConfirmation(
      context,
      title: t.iptv.removeSource,
      message: t.iptv.removeSourceMessage(name: _connection.name),
    );
    if (!ok || !mounted) return;
    Navigator.of(context).pop(IptvSourceSettingsResult.remove);
  }

  // ---- UI ---------------------------------------------------------------------

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback? onTap,
  }) => FocusableListTile(
    leading: AppIcon(icon, fill: 1),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
    trailing: trailing ?? (onTap == null ? null : const AppIcon(Symbols.chevron_right_rounded, fill: 1)),
    onTap: onTap,
  );

  Widget _switch({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => _row(
    icon: icon,
    title: title,
    subtitle: subtitle,
    trailing: Switch(value: value, onChanged: onChanged),
    onTap: () => onChanged(!value),
  );

  String _syncLine(IptvSyncRecord record, {required String Function(int count) counted}) {
    final last = record.lastSuccess;
    final base = last == null
        ? t.iptv.neverRefreshed
        : t.iptv.refreshedAt(when: DateFormat.MMMd().add_Hm().format(last), what: counted(record.count));
    final error = record.error;
    if (error == null) return base;
    if (error == IptvSyncService.interruptedError) return '$base\n${t.iptv.refreshInterrupted}';
    return '$base\n${t.iptv.lastError(error: error)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _connection;
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(c.name),
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            const SizedBox(height: 8),
            ValueListenableBuilder<IptvSourceSyncStatus>(
              valueListenable: _sync.statusOf(c.id),
              builder: (context, status, _) => SettingsGroup(
                title: t.iptv.status,
                children: [
                  if (c.isXtream && _account != null) _accountRow(theme, _account!),
                  _row(
                    icon: Symbols.list_rounded,
                    title: c.isXtream ? t.iptv.channelsMoviesSeries : t.iptv.channels,
                    subtitle: status.running
                        ? iptvSyncProgressText(status.progress)
                        : _syncLine(status.playlist, counted: (n) => t.iptv.channelsCount(count: n)),
                    trailing: status.running
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                    onTap: status.running ? null : () => unawaited(_refresh(playlist: true, guide: true)),
                  ),
                  _row(
                    icon: Symbols.calendar_view_day_rounded,
                    title: t.iptv.guide,
                    subtitle: _guideLine(c, status.epg),
                    onTap: status.running ? null : () => unawaited(_refresh(playlist: false, guide: true)),
                  ),
                  _row(
                    icon: Symbols.event_repeat_rounded,
                    title: t.iptv.refreshGuide,
                    subtitle: t.iptv.refreshGuideHint,
                    onTap: status.running ? null : () => unawaited(_refresh(playlist: false, guide: true)),
                  ),
                  _row(
                    icon: Symbols.refresh_rounded,
                    title: t.iptv.refreshNow,
                    subtitle: t.iptv.storedCounts(channels: _channelCount, programmes: _programmeCount),
                    onTap: status.running ? null : () => unawaited(_refresh(playlist: true, guide: true)),
                  ),
                ],
              ),
            ),
            SettingsGroup(
              title: t.iptv.general,
              children: [
                _row(
                  icon: Symbols.label_rounded,
                  title: t.iptv.sourceName,
                  subtitle: c.name,
                  onTap: () => _editText(
                    title: t.iptv.sourceName,
                    label: t.iptv.sourceName,
                    value: c.name,
                    allowEmpty: false,
                    apply: (v) => unawaited(_save(c.copyWith(name: v))),
                  ),
                ),
                if (c.isXtream) ...[
                  _row(
                    icon: Symbols.dns_rounded,
                    title: t.iptv.xtreamServer,
                    subtitle: c.xtreamServer,
                    onTap: () => _editText(
                      title: t.iptv.xtreamServer,
                      label: t.iptv.xtreamServer,
                      value: c.xtreamServer,
                      allowEmpty: false,
                      keyboard: TextInputType.url,
                      apply: (v) => unawaited(
                        _save(c.copyWith(xtreamServer: XtreamCredentials.normaliseBaseUrl(v)), refreshPlaylist: true),
                      ),
                    ),
                  ),
                  _row(
                    icon: Symbols.person_rounded,
                    title: t.iptv.username,
                    subtitle: c.xtreamUsername,
                    onTap: () => _editText(
                      title: t.iptv.username,
                      label: t.iptv.username,
                      value: c.xtreamUsername,
                      allowEmpty: false,
                      apply: (v) => unawaited(_save(c.copyWith(xtreamUsername: v), refreshPlaylist: true)),
                    ),
                  ),
                  _row(
                    icon: Symbols.password_rounded,
                    title: t.iptv.password,
                    subtitle: '••••••',
                    onTap: () => _editText(
                      title: t.iptv.password,
                      label: t.iptv.password,
                      value: '',
                      allowEmpty: false,
                      obscure: true,
                      apply: (v) => unawaited(_save(c.copyWith(xtreamPassword: v), refreshPlaylist: true)),
                    ),
                  ),
                  _row(
                    icon: Symbols.movie_rounded,
                    title: t.iptv.outputFormat,
                    subtitle: c.xtreamOutput == 'm3u8' ? t.iptv.outputHls : t.iptv.outputTs,
                    onTap: () async {
                      final picked = await showOptionPickerDialog<String>(
                        context,
                        title: t.iptv.outputFormat,
                        options: [
                          (icon: null, label: t.iptv.outputTs, value: 'ts'),
                          (icon: null, label: t.iptv.outputHls, value: 'm3u8'),
                        ],
                      );
                      if (picked != null && mounted) unawaited(_save(c.copyWith(xtreamOutput: picked)));
                    },
                  ),
                  _switch(
                    icon: Symbols.history_rounded,
                    title: t.iptv.timeshiftPhp,
                    subtitle: t.iptv.timeshiftPhpHint,
                    value: c.xtreamTimeshiftPhp,
                    onChanged: (v) => unawaited(_save(c.copyWith(xtreamTimeshiftPhp: v))),
                  ),
                  _switch(
                    icon: Symbols.video_library_rounded,
                    title: t.iptv.includeVod,
                    subtitle: t.iptv.includeVodHint,
                    value: c.includeVod,
                    onChanged: (v) => unawaited(_save(c.copyWith(includeVod: v), refreshPlaylist: true)),
                  ),
                ] else ...[
                  _row(
                    icon: Symbols.link_rounded,
                    title: t.iptv.playlistUrl,
                    subtitle: c.m3uFilePath != null ? t.iptv.playlistFromFile : c.m3uUrl,
                    onTap: c.m3uFilePath != null
                        ? null
                        : () => _editText(
                            title: t.iptv.playlistUrl,
                            label: t.iptv.playlistUrl,
                            value: c.m3uUrl,
                            allowEmpty: false,
                            keyboard: TextInputType.url,
                            apply: (v) => unawaited(_save(c.copyWith(m3uUrl: v), refreshPlaylist: true)),
                          ),
                  ),
                  _switch(
                    icon: Symbols.movie_rounded,
                    title: t.iptv.m3uMoviesAsVod,
                    subtitle: t.iptv.m3uMoviesAsVodHint,
                    value: c.m3uMoviesAsVod,
                    onChanged: (v) => unawaited(_save(c.copyWith(m3uMoviesAsVod: v), refreshPlaylist: true)),
                  ),
                ],
                _row(
                  icon: Symbols.schedule_rounded,
                  title: t.iptv.playlistRefresh,
                  subtitle: t.iptv.everyHours(hours: c.playlistRefreshHours),
                  onTap: () => _pickHours(
                    title: t.iptv.playlistRefresh,
                    value: c.playlistRefreshHours,
                    apply: (h) => unawaited(_save(c.copyWith(playlistRefreshHours: h))),
                  ),
                ),
                _row(
                  icon: Symbols.format_list_numbered_rounded,
                  title: t.iptv.numbering,
                  subtitle: c.numbering == IptvChannelNumbering.playlist
                      ? t.iptv.numberingPlaylist
                      : t.iptv.numberingAuto,
                  onTap: () async {
                    final picked = await showOptionPickerDialog<IptvChannelNumbering>(
                      context,
                      title: t.iptv.numbering,
                      options: [
                        (icon: null, label: t.iptv.numberingPlaylist, value: IptvChannelNumbering.playlist),
                        (icon: null, label: t.iptv.numberingAuto, value: IptvChannelNumbering.automatic),
                      ],
                    );
                    if (picked != null && mounted) unawaited(_save(c.copyWith(numbering: picked)));
                  },
                ),
              ],
            ),
            SettingsGroup(
              title: t.iptv.network,
              children: [
                _row(
                  icon: Symbols.devices_rounded,
                  title: t.iptv.userAgent,
                  subtitle: c.userAgent ?? t.iptv.notSet,
                  onTap: () => _editText(
                    title: t.iptv.userAgent,
                    label: t.iptv.userAgent,
                    value: c.userAgent,
                    apply: (v) => unawaited(
                      _save(
                        v.isEmpty ? c.copyWith(clearUserAgent: true) : c.copyWith(userAgent: v),
                        refreshPlaylist: true,
                      ),
                    ),
                  ),
                ),
                _row(
                  icon: Symbols.alt_route_rounded,
                  title: t.iptv.referrer,
                  subtitle: c.referrer ?? t.iptv.notSet,
                  onTap: () => _editText(
                    title: t.iptv.referrer,
                    label: t.iptv.referrer,
                    value: c.referrer,
                    keyboard: TextInputType.url,
                    apply: (v) => unawaited(
                      _save(
                        v.isEmpty ? c.copyWith(clearReferrer: true) : c.copyWith(referrer: v),
                        refreshPlaylist: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: t.iptv.guide,
              children: [
                _row(
                  icon: Symbols.calendar_month_rounded,
                  title: t.iptv.epgUrls,
                  subtitle: c.epgUrls.isEmpty ? t.iptv.notSet : t.iptv.guideCount(count: c.epgUrls.length),
                  onTap: () => _editText(
                    title: t.iptv.epgUrls,
                    label: t.iptv.epgUrlsHint,
                    value: c.epgUrls.join('\n'),
                    multiline: true,
                    keyboard: TextInputType.multiline,
                    apply: (v) => unawaited(
                      _save(
                        c.copyWith(
                          epgUrls: [
                            for (final l in v.split('\n'))
                              if (l.trim().isNotEmpty) l.trim(),
                          ],
                        ),
                        refreshGuide: true,
                      ),
                    ),
                  ),
                ),
                _switch(
                  icon: Symbols.cloud_download_rounded,
                  title: t.iptv.useSourceEpg,
                  subtitle: c.isXtream ? t.iptv.useSourceEpgXtream : t.iptv.useSourceEpgM3u,
                  value: c.useSourceEpg,
                  onChanged: (v) => unawaited(_save(c.copyWith(useSourceEpg: v), refreshGuide: true)),
                ),
                _row(
                  icon: Symbols.more_time_rounded,
                  title: t.iptv.guideShift,
                  subtitle: formatShiftMinutes(c.epgShiftMinutes),
                  onTap: _pickShift,
                ),
                _row(
                  icon: Symbols.history_rounded,
                  title: t.iptv.guidePastDays,
                  subtitle: t.iptv.daysCount(count: c.epgPastDays),
                  onTap: () => _pickDays(
                    title: t.iptv.guidePastDays,
                    value: c.epgPastDays,
                    max: 14,
                    apply: (d) => unawaited(_save(c.copyWith(epgPastDays: d), refreshGuide: true)),
                  ),
                ),
                _row(
                  icon: Symbols.update_rounded,
                  title: t.iptv.guideFutureDays,
                  subtitle: t.iptv.daysCount(count: c.epgFutureDays),
                  onTap: () => _pickDays(
                    title: t.iptv.guideFutureDays,
                    value: c.epgFutureDays,
                    max: 14,
                    apply: (d) => unawaited(_save(c.copyWith(epgFutureDays: d), refreshGuide: true)),
                  ),
                ),
                _row(
                  icon: Symbols.schedule_rounded,
                  title: t.iptv.guideRefresh,
                  subtitle: t.iptv.everyHours(hours: c.epgRefreshHours),
                  onTap: () => _pickHours(
                    title: t.iptv.guideRefresh,
                    value: c.epgRefreshHours,
                    apply: (h) => unawaited(_save(c.copyWith(epgRefreshHours: h))),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              title: t.iptv.channelsAndGroups,
              children: [
                _row(
                  icon: Symbols.folder_rounded,
                  title: t.iptv.groups,
                  subtitle: t.iptv.groupsHint,
                  onTap: () async {
                    final locked = await Navigator.of(context).push<List<String>>(
                      MaterialPageRoute(
                        builder: (_) => IptvGroupEditorScreen(
                          sourceId: c.id,
                          lockedGroups: c.lockedGroups,
                          store: widget.store,
                          includeVod: c.isXtream ? c.includeVod : c.m3uMoviesAsVod,
                        ),
                      ),
                    );
                    if (locked != null && mounted) {
                      unawaited(_save(c.copyWith(lockedGroups: locked)));
                    } else {
                      IptvDataRevision.bump(c.id);
                    }
                  },
                ),
                _row(
                  icon: Symbols.tv_rounded,
                  title: t.iptv.channels,
                  subtitle: t.iptv.channelsHint,
                  onTap: () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => IptvChannelEditorScreen(connection: c, store: widget.store),
                      ),
                    );
                    IptvDataRevision.bump(c.id);
                  },
                ),
                if (c.lockedGroups.isNotEmpty)
                  IptvParentalGate.isUnlocked(c.id)
                      ? _row(
                          icon: Symbols.lock_rounded,
                          title: t.iptv.hideLockedGroups,
                          subtitle: t.iptv.lockedGroupsShown,
                          onTap: () {
                            IptvParentalGate.lock(c.id);
                            setState(() {});
                          },
                        )
                      : _row(
                          icon: Symbols.lock_open_rounded,
                          title: t.iptv.showLockedGroups,
                          subtitle: t.iptv.lockedGroupsCount(count: c.lockedGroups.length),
                          onTap: _unlockParental,
                        ),
              ],
            ),
            SettingsGroup(
              children: [_row(icon: Symbols.delete_rounded, title: t.iptv.removeSource, onTap: _remove)],
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ],
    );
  }

  Widget _accountRow(ThemeData theme, XtreamAccount account) {
    final expiry = account.expiresAt;
    final parts = [
      t.iptv.accountStatus(status: account.status ?? '-'),
      expiry == null ? t.iptv.accountNoExpiry : t.iptv.accountExpires(date: DateFormat.yMMMd().format(expiry)),
      if (account.maxConnections != null)
        t.iptv.accountConnections(active: account.activeConnections ?? 0, max: account.maxConnections!),
      if (account.isTrial) t.iptv.accountTrial,
    ];
    return _row(
      icon: account.isActive ? Symbols.verified_user_rounded : Symbols.gpp_bad_rounded,
      title: t.iptv.account,
      subtitle: parts.join(' · '),
      onTap: null,
    );
  }
}

/// What the settings screen asks its caller to do.
enum IptvSourceSettingsResult { remove }

/// `+1 h 30 min`, `−30 min`, `None`.
String formatShiftMinutes(int minutes) {
  if (minutes == 0) return t.iptv.noShift;
  final sign = minutes > 0 ? '+' : '−';
  final abs = minutes.abs();
  final h = abs ~/ 60;
  final m = abs % 60;
  return '$sign${[if (h > 0) '$h h', if (m > 0) '$m min'].join(' ')}';
}

/// Exposed for the channel editor's number field.
final List<TextInputFormatter> iptvNumberFormatters = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
