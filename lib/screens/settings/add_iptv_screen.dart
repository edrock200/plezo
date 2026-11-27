import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../services/file_picker_service.dart';
import '../../services/iptv/iptv_sync_service.dart';
import '../../services/iptv/iptv_sync_worker.dart';
import '../../services/iptv/xtream_api.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../profile/profile_switch_screen.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';

/// Add an IPTV source: an M3U playlist (address, or a file on phone and
/// desktop) or an Xtream Codes login (server, username, password), plus
/// optional guide (XMLTV) addresses.
///
/// The channel list is read once before the source is saved, so a wrong
/// address or login is reported here; the guide is read in the background
/// afterwards. The screen names no provider and suggests none: the user
/// brings their own source.
///
/// Every control is a focusable with explicit D-pad neighbours.
class AddIptvScreen extends StatefulWidget {
  final Profile? targetProfile;

  /// Test seam: the refresh service (its store and isolate use).
  @visibleForTesting
  final IptvSyncService? syncService;

  /// Test seam: skip binding (no providers in a widget test).
  @visibleForTesting
  final Future<void> Function(IptvConnection connection)? onSaved;

  const AddIptvScreen({super.key, this.targetProfile, this.syncService, this.onSaved});

  @override
  State<AddIptvScreen> createState() => _AddIptvScreenState();
}

class _AddIptvScreenState extends State<AddIptvScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  final _formKey = GlobalKey<FormState>();
  IptvSourceType _type = IptvSourceType.m3u;

  late final _nameController = createTextEditingController();
  late final _urlController = createTextEditingController();
  late final _serverController = createTextEditingController();
  late final _userController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  late final _epgController = createTextEditingController();

  final _m3uTabFocus = FocusNode(debugLabel: 'AddIptv:M3uTab');
  final _xtreamTabFocus = FocusNode(debugLabel: 'AddIptv:XtreamTab');
  final _nameFocus = FocusNode(debugLabel: 'AddIptv:Name');
  final _urlFocus = FocusNode(debugLabel: 'AddIptv:Url');
  final _fileFocus = FocusNode(debugLabel: 'AddIptv:File');
  final _useXtreamFocus = FocusNode(debugLabel: 'AddIptv:UseXtream');
  final _serverFocus = FocusNode(debugLabel: 'AddIptv:Server');
  final _userFocus = FocusNode(debugLabel: 'AddIptv:User');
  final _passwordFocus = FocusNode(debugLabel: 'AddIptv:Password');
  final _epgFocus = FocusNode(debugLabel: 'AddIptv:Epg');
  final _addFocus = FocusNode(debugLabel: 'AddIptv:Add');

  /// A picked playlist file (copied into the app's storage on save).
  String? _pickedFile;
  String? _pickedFileName;

  /// The source being imported, for its progress line.
  String? _importingId;

  IptvSyncService get _sync => widget.syncService ?? IptvSyncService.instance;

  bool get _canPickFile => !PlatformDetector.isTV();

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    for (final node in [
      _m3uTabFocus,
      _xtreamTabFocus,
      _nameFocus,
      _urlFocus,
      _fileFocus,
      _useXtreamFocus,
      _serverFocus,
      _userFocus,
      _passwordFocus,
      _epgFocus,
      _addFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  XtreamCredentials? _detected;

  void _onUrlChanged() {
    final detected = XtreamCredentials.fromM3uUrl(_urlController.text);
    if ((detected == null) != (_detected == null)) setState(() => _detected = detected);
    _detected = detected;
  }

  void _useDetectedXtream() {
    final d = _detected;
    if (d == null) return;
    setState(() {
      _type = IptvSourceType.xtream;
      _serverController.text = d.baseUrl;
      _userController.text = d.username;
      _passwordController.text = d.password;
    });
    requestFocusAfterFrame(_serverFocus);
  }

  void _setType(IptvSourceType type) {
    if (_type == type) return;
    setState(() => _type = type);
  }

  Future<void> _pickFile() async {
    final result = await FilePickerService.instance.pickFiles(
      // Any file: Android has no MIME type for .m3u to filter by.
      type: FileType.any,
    );
    final path = result?.files.singleOrNull?.path;
    if (path == null || !mounted) return;
    setState(() {
      _pickedFile = path;
      _pickedFileName = p.basename(path);
      _urlController.clear();
    });
  }

  static List<String> _epgUrls(String text) => [
    for (final line in text.split(RegExp(r'[\n,]')))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  String _defaultName() {
    final name = _nameController.text.trim();
    if (name.isNotEmpty) return name;
    final address = _type == IptvSourceType.xtream ? _serverController.text : _urlController.text;
    final host = Uri.tryParse(address.contains('://') ? address : 'http://$address')?.host ?? '';
    if (host.isNotEmpty) return host;
    if (_pickedFileName != null) return p.basenameWithoutExtension(_pickedFileName!);
    return t.iptv.defaultSourceName;
  }

  Future<String?> _copyPickedFile(String id) async {
    final picked = _pickedFile;
    if (picked == null) return null;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'iptv_playlists'));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, '$id.m3u'));
    await File(picked).copy(target.path);
    return target.path;
  }

  Future<void> _add() async {
    if (busy || !(_formKey.currentState?.validate() ?? false)) return;
    if (_type == IptvSourceType.m3u && _pickedFile == null && _urlController.text.trim().isEmpty) {
      setErrorText(t.iptv.addressOrFileRequired);
      return;
    }
    final id = IptvConnection.newId();
    final saved = await runAsync<IptvConnection?>(
      () async {
        final filePath = _type == IptvSourceType.m3u ? await _copyPickedFile(id) : null;
        final connection = IptvConnection(
          id: id,
          sourceType: _type,
          name: _defaultName(),
          m3uUrl: _type == IptvSourceType.m3u && filePath == null ? _urlController.text.trim() : '',
          m3uFilePath: filePath,
          xtreamServer: _type == IptvSourceType.xtream
              ? XtreamCredentials.normaliseBaseUrl(_serverController.text)
              : '',
          xtreamUsername: _type == IptvSourceType.xtream ? _userController.text.trim() : '',
          xtreamPassword: _type == IptvSourceType.xtream ? _passwordController.text : '',
          epgUrls: _epgUrls(_epgController.text),
          createdAt: DateTime.now(),
          lastAuthenticatedAt: DateTime.now(),
        );
        setState(() => _importingId = id);
        await _sync.refresh(id, connection: connection, playlist: true, epg: false, vod: false);
        final record = await _sync.store.syncRecord(id, IptvSyncWorker.playlistKind);
        if (record.lastSuccess == null) {
          await _sync.store.deleteSource(id);
          if (filePath != null) unawaited(File(filePath).delete().catchError((_) => File(filePath)));
          throw _ImportFailure(record.error);
        }
        // The guide follows in the background (automatic refreshes may not
        // have started yet this run).
        unawaited(_sync.refresh(id, connection: connection, playlist: false, epg: true, vod: true));
        return connection;
      },
      errorMapper: (e) {
        if (e is _ImportFailure) {
          return switch (e.reason) {
            'login refused' || 'HTTP 401' || 'HTTP 403' => t.iptv.loginRefused,
            'the playlist has no channels' => t.iptv.playlistEmpty,
            final String reason => t.iptv.importFailed(reason: reason),
            null => t.iptv.importFailed(reason: '-'),
          };
        }
        appLogger.w('[iptv] add source failed (${e.runtimeType})');
        return t.iptv.importFailed(reason: e.runtimeType.toString());
      },
    );
    if (mounted) setState(() => _importingId = null);
    if (saved == null || !mounted) return;
    appLogger.i('[iptv] source added type=${saved.sourceType.name}');
    if (widget.onSaved != null) {
      await widget.onSaved!(saved);
    } else {
      await _persistAndBind(saved);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _persistAndBind(IptvConnection connection) async {
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return;
    final targetProfile = widget.targetProfile;
    var boundProfile = targetProfile ?? activeProvider.active;
    final hasProfiles = activeProvider.profiles.isNotEmpty;
    if (targetProfile == null && activeProvider.active == null && hasProfiles) {
      await Navigator.of(
        context,
        rootNavigator: true,
      ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
      if (!mounted) return;
      boundProfile = activeProvider.active;
    }
    Profile? newProfile;
    if (boundProfile == null && !hasProfiles) {
      final now = DateTime.now();
      newProfile = Profile.local(
        id: 'local-${const Uuid().v4()}',
        displayName: connection.name,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
      );
      boundProfile = newProfile;
    }
    final bindProfile = boundProfile;
    if (bindProfile == null) {
      setErrorText(t.messages.noProfilesAvailable);
      return;
    }
    await persistAndBindConnection(
      context: context,
      connection: connection,
      bindToProfile: ProfileConnection(
        profileId: bindProfile.id,
        connectionId: connection.id,
        userToken: null,
        userIdentifier: connection.id,
        tokenAcquiredAt: DateTime.now(),
      ),
      firstRunProfile: newProfile,
    );
    if (!mounted) return;
    if (bindProfile.id == activeProvider.activeId) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  FocusNode get _firstSourceField => _type == IptvSourceType.m3u ? _urlFocus : _serverFocus;

  FocusNode get _lastSourceField {
    if (_type == IptvSourceType.xtream) return _passwordFocus;
    if (_detected != null) return _useXtreamFocus;
    return _canPickFile ? _fileFocus : _urlFocus;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.iptv.addSourceTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: .stretch,
                    children: [
                      Text(t.iptv.addSourceIntro, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 16),
                      _typeSelector(),
                      const SizedBox(height: 16),
                      _nameField(),
                      const SizedBox(height: 12),
                      if (_type == IptvSourceType.m3u) ..._m3uFields(theme) else ..._xtreamFields(),
                      const SizedBox(height: 12),
                      _epgField(),
                      const SizedBox(height: 20),
                      _addButton(),
                      ..._progressLine(theme),
                      ...buildInlineError(theme),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _typeSelector() {
    Widget tab(IptvSourceType type, FocusNode node, String label, IconData icon) {
      final selected = _type == type;
      final button = selected
          ? FilledButton.icon(onPressed: () => _setType(type), icon: AppIcon(icon, fill: 1), label: Text(label))
          : OutlinedButton.icon(onPressed: () => _setType(type), icon: AppIcon(icon, fill: 1), label: Text(label));
      return Expanded(
        child: FocusableButton(
          focusNode: node,
          autofocus: type == IptvSourceType.m3u,
          useBackgroundFocus: true,
          onPressed: busy ? null : () => _setType(type),
          onNavigateLeft: type == IptvSourceType.xtream ? () => _m3uTabFocus.requestFocus() : null,
          onNavigateRight: type == IptvSourceType.m3u ? () => _xtreamTabFocus.requestFocus() : null,
          onNavigateDown: () => _nameFocus.requestFocus(),
          child: button,
        ),
      );
    }

    return Row(
      children: [
        tab(IptvSourceType.m3u, _m3uTabFocus, t.iptv.typeM3u, Symbols.playlist_play_rounded),
        const SizedBox(width: 12),
        tab(IptvSourceType.xtream, _xtreamTabFocus, t.iptv.typeXtream, Symbols.login_rounded),
      ],
    );
  }

  Widget _nameField() => FocusableTextFormField(
    controller: _nameController,
    focusNode: _nameFocus,
    enabled: !busy,
    tvTextInputPresentation: TvTextInputPresentation.platform,
    tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
    onNavigateUp: () => (_type == IptvSourceType.m3u ? _m3uTabFocus : _xtreamTabFocus).requestFocus(),
    onNavigateDown: () => _firstSourceField.requestFocus(),
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(labelText: t.iptv.sourceName, hintText: t.iptv.sourceNameHint),
  );

  List<Widget> _m3uFields(ThemeData theme) => [
    FocusableTextFormField(
      controller: _urlController,
      focusNode: _urlFocus,
      enabled: !busy,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      tvTextInputPresentation: TvTextInputPresentation.platform,
      tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
      onNavigateUp: () => _nameFocus.requestFocus(),
      onNavigateDown: () =>
          (_canPickFile ? _fileFocus : (_detected != null ? _useXtreamFocus : _epgFocus)).requestFocus(),
      textInputAction: TextInputAction.next,
      validator: (value) {
        final text = value?.trim() ?? '';
        if (text.isEmpty) return null;
        final uri = Uri.tryParse(text);
        if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'file')) {
          return t.iptv.invalidAddress;
        }
        return null;
      },
      decoration: InputDecoration(labelText: t.iptv.playlistUrl, hintText: 'https://…/playlist.m3u'),
    ),
    if (_canPickFile) ...[
      const SizedBox(height: 8),
      FocusableButton(
        focusNode: _fileFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _urlFocus.requestFocus(),
        onNavigateDown: () => (_detected != null ? _useXtreamFocus : _epgFocus).requestFocus(),
        onPressed: busy ? null : () => unawaited(_pickFile()),
        child: OutlinedButton.icon(
          onPressed: busy ? null : () => unawaited(_pickFile()),
          icon: const AppIcon(Symbols.folder_open_rounded, fill: 1),
          label: Text(_pickedFileName == null ? t.iptv.chooseFile : t.iptv.chosenFile(name: _pickedFileName!)),
        ),
      ),
    ],
    if (_detected != null) ...[
      const SizedBox(height: 8),
      FocusableButton(
        focusNode: _useXtreamFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => (_canPickFile ? _fileFocus : _urlFocus).requestFocus(),
        onNavigateDown: () => _epgFocus.requestFocus(),
        onPressed: busy ? null : _useDetectedXtream,
        child: TextButton.icon(
          onPressed: busy ? null : _useDetectedXtream,
          icon: const AppIcon(Symbols.swap_horiz_rounded, fill: 1),
          label: Text(t.iptv.useAsXtream),
        ),
      ),
    ],
  ];

  List<Widget> _xtreamFields() => [
    FocusableTextFormField(
      controller: _serverController,
      focusNode: _serverFocus,
      enabled: !busy,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      tvTextInputPresentation: TvTextInputPresentation.platform,
      tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
      onNavigateUp: () => _nameFocus.requestFocus(),
      onNavigateDown: () => _userFocus.requestFocus(),
      textInputAction: TextInputAction.next,
      validator: (value) => (value?.trim() ?? '').isEmpty ? t.iptv.serverRequired : null,
      decoration: InputDecoration(labelText: t.iptv.xtreamServer, hintText: 'http://host:port'),
    ),
    const SizedBox(height: 12),
    FocusableTextFormField(
      controller: _userController,
      focusNode: _userFocus,
      enabled: !busy,
      autocorrect: false,
      enableSuggestions: false,
      tvTextInputPresentation: TvTextInputPresentation.platform,
      onNavigateUp: () => _serverFocus.requestFocus(),
      onNavigateDown: () => _passwordFocus.requestFocus(),
      textInputAction: TextInputAction.next,
      validator: (value) => (value?.trim() ?? '').isEmpty ? t.iptv.usernameRequired : null,
      decoration: InputDecoration(labelText: t.iptv.username),
    ),
    const SizedBox(height: 12),
    FocusableTextFormField(
      controller: _passwordController,
      focusNode: _passwordFocus,
      enabled: !busy,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      tvTextInputPresentation: TvTextInputPresentation.platform,
      onNavigateUp: () => _userFocus.requestFocus(),
      onNavigateDown: () => _epgFocus.requestFocus(),
      textInputAction: TextInputAction.next,
      validator: (value) => (value ?? '').isEmpty ? t.iptv.passwordRequired : null,
      decoration: InputDecoration(labelText: t.iptv.password),
    ),
  ];

  Widget _epgField() => FocusableTextFormField(
    controller: _epgController,
    focusNode: _epgFocus,
    enabled: !busy,
    keyboardType: TextInputType.multiline,
    autocorrect: false,
    enableSuggestions: false,
    maxLines: 3,
    tvTextInputPresentation: TvTextInputPresentation.platform,
    onNavigateUp: () => _lastSourceField.requestFocus(),
    onNavigateDown: () => _addFocus.requestFocus(),
    decoration: InputDecoration(
      labelText: t.iptv.epgUrls,
      hintText: t.iptv.epgUrlsHint,
      helperText: t.iptv.epgUrlsHelp,
      helperMaxLines: 3,
    ),
  );

  Widget _addButton() => FocusableButton(
    focusNode: _addFocus,
    useBackgroundFocus: true,
    onNavigateUp: () => _epgFocus.requestFocus(),
    onPressed: busy ? null : () => unawaited(_add()),
    child: FilledButton.icon(
      onPressed: busy ? null : () => unawaited(_add()),
      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.add_rounded, fill: 1),
      label: Text(t.iptv.addSource),
    ),
  );

  List<Widget> _progressLine(ThemeData theme) {
    final id = _importingId;
    if (id == null) return const [];
    return [
      const SizedBox(height: 12),
      ValueListenableBuilder<IptvSourceSyncStatus>(
        valueListenable: _sync.statusOf(id),
        builder: (context, status, _) =>
            Text(iptvSyncProgressText(status.progress), style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
      ),
    ];
  }
}

class _ImportFailure implements Exception {
  const _ImportFailure(this.reason);
  final String? reason;
}

/// A refresh's progress in words.
String iptvSyncProgressText(IptvSyncProgress? progress) {
  if (progress == null) return t.iptv.progressStarting;
  return switch (progress.phase) {
    IptvSyncPhase.idle => '',
    IptvSyncPhase.playlist =>
      progress.count > 0 ? t.iptv.progressChannelsCount(count: progress.count) : t.iptv.progressChannels,
    IptvSyncPhase.movies => t.iptv.progressMovies,
    IptvSyncPhase.series => t.iptv.progressSeries,
    IptvSyncPhase.guide => progress.count > 0 ? t.iptv.progressGuideCount(count: progress.count) : t.iptv.progressGuide,
    IptvSyncPhase.matching => t.iptv.progressMatching,
    IptvSyncPhase.done => t.iptv.progressDone,
    IptvSyncPhase.failed => t.iptv.progressFailed(reason: progress.message ?? '-'),
  };
}
