import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../focus/card_focus_scope.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../services/tofa/tofa_api.dart';
import '../../services/tofa/tofa_auth_service.dart';
import '../../services/tofa/tofa_endpoints.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../profile/pin_entry_dialog.dart';
import '../profile/profile_switch_screen.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';

/// Product name shown in the UI; not localized.
const _tofa = 'Tofa';

/// Add a Tofa server:
///   1. Find the server at the address (`GET /api/v1/auth/status`). It must
///      be claimed and name its `server_id` and cloud service.
///   2. Sign in with a device code at the cloud service (`connect_url`): the
///      code and a QR code of the approval link, polled until approved.
///   3. Pick one of the account's Tofa profiles, entering its PIN when it is
///      locked. One account profile is one connection.
///   4. Persist the connection and bind it to [targetProfile] (or the active
///      Plezilo profile), with the same first-run rules as Silo.
///
/// Every control works with touch and the D-pad: the text field, buttons and
/// profile tiles are focusables with explicit neighbours.
class AddTofaScreen extends StatefulWidget {
  final Profile? targetProfile;

  /// Prefills the address (a "sign in again" from a saved connection).
  final String? initialUrl;

  /// Test seam: the sign-in service.
  @visibleForTesting
  final TofaAuthService? authService;

  /// Test seam: how the device flow waits between polls.
  @visibleForTesting
  final Future<void> Function(Duration delay)? pollWait;

  /// Tofa's cloud service for account-first sign-in (test seam).
  final String cloudUrl;

  const AddTofaScreen({
    super.key,
    this.targetProfile,
    this.initialUrl,
    this.authService,
    this.pollWait,
    this.cloudUrl = tofaCloudUrl,
  });

  @override
  State<AddTofaScreen> createState() => _AddTofaScreenState();
}

enum _Step { address, deviceCode, servers, profile }

class _AddTofaScreenState extends State<AddTofaScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController(text: widget.initialUrl ?? '');
  final _urlFocus = FocusNode(debugLabel: 'AddTofa:Url');
  final _findServerFocus = FocusNode(debugLabel: 'AddTofa:FindServer');
  final _accountFocus = FocusNode(debugLabel: 'AddTofa:Account');
  final _serversBackFocus = FocusNode(debugLabel: 'AddTofa:ServersBack');
  final _newCodeFocus = FocusNode(debugLabel: 'AddTofa:NewCode');
  final _codeChangeServerFocus = FocusNode(debugLabel: 'AddTofa:CodeChangeServer');
  final _profileChangeServerFocus = FocusNode(debugLabel: 'AddTofa:ProfileChangeServer');
  final _formKey = GlobalKey<FormState>();

  _Step _step = _Step.address;
  TofaAuthService? _auth;
  TofaServerInfo? _server;
  TofaDeviceSignIn? _flow;
  TofaSignIn? _signIn;
  List<TofaProfile> _profiles = const [];

  /// The code was approved and the account is being read.
  bool _completing = false;

  /// Account-first sign-in: the cloud token of the approved code and the
  /// account's servers, while the person picks one.
  TofaTokens? _cloudTokens;
  List<TofaCloudServer> _servers = const [];

  @override
  void dispose() {
    _disposeFlow();
    if (widget.authService == null) _auth?.close();
    _urlFocus.dispose();
    _findServerFocus.dispose();
    _accountFocus.dispose();
    _serversBackFocus.dispose();
    _newCodeFocus.dispose();
    _codeChangeServerFocus.dispose();
    _profileChangeServerFocus.dispose();
    super.dispose();
  }

  Future<TofaAuthService> _authService() async => _auth ??= widget.authService ?? await TofaAuthService.create();

  void _disposeFlow() {
    final flow = _flow;
    _flow = null;
    if (flow == null) return;
    flow.removeListener(_onFlowChanged);
    flow.dispose();
  }

  // ---------------------------------------------------------------------------
  // Steps
  // ---------------------------------------------------------------------------

  Future<void> _probe() async {
    if (busy || !(_formKey.currentState?.validate() ?? false)) return;
    final input = _urlController.text.trim();
    final server = await runAsync(
      () async => (await _authService()).probeServer(input),
      errorMapper: (e) => e is MediaServerUrlException ? t.addServer.tofaNotATofaServer : t.addServer.tofaSignInFailed,
    );
    if (server == null || !mounted) return;
    if (!server.canSignIn) {
      appLogger.i('[tofa] server cannot sign devices in (claimed=${server.claimed} pending=${server.claimPending})');
      setErrorText(t.addServer.tofaNotClaimed);
      return;
    }
    _server = server;
    await _startDeviceFlow();
  }

  /// Account-first sign-in: a code for the account (no server yet), then
  /// the account's servers to pick from. Works away from home from the start.
  Future<void> _startAccountFlow() async {
    if (busy) return;
    _server = null;
    await _startDeviceFlow();
  }

  Future<void> _startDeviceFlow() async {
    final server = _server;
    _disposeFlow();
    final auth = await _authService();
    final flow = server == null
        ? TofaDeviceSignIn.account(auth: auth, cloudUrl: widget.cloudUrl, wait: widget.pollWait)
        : TofaDeviceSignIn(auth: auth, server: server, wait: widget.pollWait);
    if (!mounted) {
      flow.dispose();
      return;
    }
    flow.addListener(_onFlowChanged);
    setErrorText(null);
    setState(() {
      _flow = flow;
      _completing = false;
      _step = _Step.deviceCode;
    });
    requestFocusAfterFrame(_codeChangeServerFocus);
    unawaited(flow.start());
  }

  void _onFlowChanged() {
    final flow = _flow;
    if (flow == null || !mounted) return;
    final state = flow.value;
    setState(() {});
    if (state.status == TofaDeviceSignInStatus.approved && state.tokens != null && !_completing) {
      unawaited(_completeSignIn(flow, state));
    } else if (state.status.isSettled) {
      requestFocusAfterFrame(_newCodeFocus);
    }
  }

  Future<void> _completeSignIn(TofaDeviceSignIn flow, TofaDeviceSignInState state) async {
    final server = _server;
    final tokens = state.tokens;
    if (tokens == null) return;
    if (server == null) return _completeAccountSignIn(flow, tokens);
    setState(() => _completing = true);
    await _readProfiles(flow, server, tokens);
  }

  /// The account's servers, from the cloud token the account code granted.
  Future<void> _completeAccountSignIn(TofaDeviceSignIn flow, TofaTokens cloudTokens) async {
    setState(() => _completing = true);
    List<TofaCloudServer>? servers;
    try {
      servers = await (await _authService()).listServers(widget.cloudUrl, cloudTokens);
    } catch (e) {
      appLogger.w('[tofa] server list failed', error: e.runtimeType);
    }
    if (!mounted || !identical(_flow, flow)) return;
    _disposeFlow();
    setState(() {
      _completing = false;
      _cloudTokens = cloudTokens;
      _servers = servers ?? const [];
      _step = _Step.servers;
    });
    setErrorText(
      servers == null
          ? t.addServer.tofaSignInFailed
          : servers.isEmpty
          ? t.addServer.tofaNoServers
          : null,
    );
    if (_servers.isEmpty) requestFocusAfterFrame(_serversBackFocus);
  }

  /// A server picked from the account's list: its 30-day server token pair
  /// (`server-session`), then its profiles.
  Future<void> _pickServer(TofaCloudServer picked) async {
    final cloudTokens = _cloudTokens;
    if (busy || cloudTokens == null) return;
    final tokens = await runAsync(
      () async => (await _authService()).serverSession(widget.cloudUrl, cloudTokens, picked),
      errorMapper: (_) => t.addServer.tofaSignInFailed,
    );
    if (tokens == null || !mounted) return;
    // Find an address of this server that answers from here (home network,
    // internet, custom URL or relay) before reading its profiles.
    final info = await runAsync(
      () async => (await _authService()).resolveServerAddress(widget.cloudUrl, picked, tokens),
      errorMapper: (_) => t.addServer.tofaServerUnreachable,
    );
    if (!mounted) return;
    if (info == null) {
      setErrorText(t.addServer.tofaServerUnreachable);
      return;
    }
    _server = info;
    setState(() => _completing = true);
    await _readProfiles(null, info, tokens);
  }

  Future<void> _readProfiles(TofaDeviceSignIn? flow, TofaServerInfo server, TofaTokens tokens) async {
    final auth = await _authService();
    final account = await auth.fetchAccount(server, tokens);
    final signIn = TofaSignIn(server: server, tokens: tokens, account: account);
    List<TofaProfile>? profiles;
    try {
      profiles = await auth.fetchProfiles(signIn);
    } catch (e) {
      appLogger.w('[tofa] profile list failed', error: e.runtimeType);
    }
    if (!mounted || (flow != null && !identical(_flow, flow))) return;
    _disposeFlow();
    setState(() {
      _completing = false;
      _signIn = signIn;
      _profiles = profiles ?? const [];
      _step = _Step.profile;
    });
    if (profiles == null) {
      setErrorText(t.addServer.tofaSignInFailed);
    } else if (profiles.isEmpty) {
      setErrorText(t.addServer.tofaNoProfiles);
    } else {
      setErrorText(null);
    }
    if (_profiles.isEmpty) requestFocusAfterFrame(_profileChangeServerFocus);
  }

  void _changeServer() {
    _disposeFlow();
    setErrorText(null);
    setState(() {
      _server = null;
      _signIn = null;
      _profiles = const [];
      _cloudTokens = null;
      _servers = const [];
      _completing = false;
      _step = _Step.address;
    });
    requestFocusAfterFrame(_urlFocus);
  }

  Future<void> _pickProfile(TofaProfile profile) async {
    if (busy) return;
    final signIn = _signIn;
    if (signIn == null) return;
    TofaPinAccepted? pin;
    if (profile.isLocked) {
      String? error;
      while (true) {
        final entered = await showPinEntryDialog(context, profile.name, errorMessage: error);
        if (entered == null || !mounted) return;
        setErrorText(null);
        setBusy(true);
        TofaPinResult? result;
        try {
          result = await (await _authService()).verifyPin(signIn, profile, entered);
        } catch (e) {
          appLogger.d('[tofa] PIN check failed', error: e.runtimeType);
        } finally {
          setBusy(false);
        }
        if (!mounted || !identical(signIn, _signIn)) return;
        switch (result) {
          case final TofaPinAccepted accepted:
            pin = accepted;
          case TofaPinWrong():
            error = t.addServer.tofaWrongPin;
          case TofaPinTooManyTries():
            error = t.addServer.tofaTooManyPinAttempts;
          case null:
            error = t.addServer.tofaPinNetworkError;
        }
        if (pin != null) break;
      }
    }
    final connection = TofaAuthService.buildConnection(signIn, profile, pin: pin);
    await runAsync<void>(
      () => _persistAndExit(connection),
      errorMapper: (e) {
        appLogger.e('[tofa] saving the connection failed', error: e);
        return t.addServer.tofaSignInFailed;
      },
    );
  }

  Future<void> _persistAndExit(TofaConnection connection) async {
    if (!mounted) return;
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
      if (boundProfile == null) {
        setErrorText(t.messages.noProfilesAvailable);
        return;
      }
    }

    Profile? newProfile;
    var separateProfile = false;
    if (targetProfile == null && boundProfile == null && !hasProfiles) {
      newProfile = _newProfile(connection.profileName.isNotEmpty ? connection.profileName : connection.serverName);
      boundProfile = newProfile;
    } else if (boundProfile != null) {
      // One Plezilo profile uses one account per Tofa server (one active
      // client per server): another account there gets a profile of its own.
      final registry = context.read<ConnectionRegistry>();
      final joinRows = await context.read<ProfileConnectionRegistry>().listForProfile(boundProfile.id);
      final byId = {for (final c in await registry.list()) c.id: c};
      if (!mounted) return;
      final clash = joinRows.any(
        (row) =>
            row.connectionId != connection.id &&
            byId[row.connectionId] is TofaConnection &&
            (byId[row.connectionId] as TofaConnection).serverId == connection.serverId,
      );
      if (clash) {
        appLogger.i('[tofa] the profile already uses another account on this server; new profile');
        final taken = {for (final p in activeProvider.profiles) p.displayName.toLowerCase()};
        var name = '${connection.profileName} · ${connection.serverName}';
        for (var n = 2; taken.contains(name.toLowerCase()); n++) {
          name = '${connection.profileName} $n';
        }
        newProfile = _newProfile(name);
        boundProfile = newProfile;
        separateProfile = true;
      }
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
        // The connection row holds Tofa's rotating tokens; the join row keeps none.
        userToken: null,
        userIdentifier: connection.userId,
        tokenAcquiredAt: DateTime.now(),
      ),
      firstRunProfile: newProfile,
      activateFirstRunProfile: !separateProfile,
    );
    appLogger.i('[tofa] connection saved');
    if (!mounted) return;
    if (bindProfile.id == activeProvider.activeId) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  static Profile _newProfile(String name) {
    final now = DateTime.now();
    return Profile.local(
      id: 'local-${const Uuid().v4()}',
      displayName: name,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flowState = _flow?.value;
    return FocusedScrollScaffold(
      title: Text(t.addServer.addMediaBrowserTitle(product: _tofa)),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: .stretch,
                children: switch (_step) {
                  _Step.address => _buildAddressStep(theme),
                  _Step.deviceCode when flowState != null => [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: _buildDeviceCodePanel(theme, flowState),
                      ),
                    ),
                  ],
                  _Step.deviceCode => _buildAddressStep(theme),
                  _Step.servers => _buildServersStep(theme),
                  _Step.profile => _buildProfileStep(theme),
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildAddressStep(ThemeData theme) => [
    FocusableTextFormField(
      controller: _urlController,
      focusNode: _urlFocus,
      tvTextInputPresentation: TvTextInputPresentation.platform,
      autofocus: true,
      tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      enabled: !busy,
      onNavigateDown: () => _findServerFocus.requestFocus(),
      textInputAction: TextInputAction.go,
      onFieldSubmitted: busy ? null : (_) => unawaited(_probe()),
      decoration: InputDecoration(
        labelText: t.addServer.serverUrl,
        // URL example — intentionally not localized.
        hintText: 'http://192.168.1.20:8096',
        prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
      ),
      validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
    ),
    const SizedBox(height: 16),
    FocusableButton(
      focusNode: _findServerFocus,
      useBackgroundFocus: true,
      onNavigateUp: () => _urlFocus.requestFocus(),
      onNavigateDown: () => _accountFocus.requestFocus(),
      onPressed: busy ? null : () => unawaited(_probe()),
      child: FilledButton.icon(
        onPressed: busy ? null : () => unawaited(_probe()),
        icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.travel_explore_rounded, fill: 1),
        label: Text(t.addServer.findServer),
      ),
    ),
    const SizedBox(height: 24),
    Text(
      t.addServer.tofaAccountLead,
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
    ),
    const SizedBox(height: 8),
    FocusableButton(
      focusNode: _accountFocus,
      useBackgroundFocus: true,
      onNavigateUp: () => _findServerFocus.requestFocus(),
      onPressed: busy ? null : () => unawaited(_startAccountFlow()),
      child: OutlinedButton.icon(
        onPressed: busy ? null : () => unawaited(_startAccountFlow()),
        icon: const AppIcon(Symbols.account_circle_rounded, fill: 1),
        label: Text(t.addServer.tofaSignInWithAccount),
      ),
    ),
    ...buildInlineError(theme),
  ];

  List<Widget> _buildServersStep(ThemeData theme) {
    final tokensRef = tokens(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return [
      Text(t.addServer.tofaChooseServer, style: theme.textTheme.titleLarge),
      const SizedBox(height: 16),
      for (final (i, server) in _servers.indexed) ...[
        if (i > 0) SizedBox(height: tokensRef.groupGap),
        _TofaChoiceTile(
          title: server.name,
          subtitle: server.online ? null : t.addServer.tofaServerOffline,
          leading: const AppIcon(Symbols.dns_rounded, fill: 1),
          autofocus: i == 0,
          borderRadius: groupItemRadii(context, i, _servers.length),
          onTap: busy ? null : () => unawaited(_pickServer(server)),
        ),
      ],
      ...buildInlineError(theme),
      if (busy) ...[const SizedBox(height: 12), const Center(child: LoadingIndicatorBox(size: 20))],
      const SizedBox(height: 16),
      Text(t.addServer.tofaRelayNote, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusableButton(
          focusNode: _serversBackFocus,
          useBackgroundFocus: true,
          onPressed: busy ? null : _changeServer,
          child: TextButton.icon(
            onPressed: busy ? null : _changeServer,
            icon: const AppIcon(Symbols.arrow_back_rounded, fill: 1),
            label: Text(t.addServer.tofaChangeServer),
          ),
        ),
      ),
    ];
  }

  String _statusText(TofaDeviceSignInState state) {
    if (_completing) return t.addServer.tofaDeviceSigningIn;
    return switch (state.status) {
      TofaDeviceSignInStatus.gettingCode => t.addServer.tofaDeviceGettingCode,
      TofaDeviceSignInStatus.waiting => t.addServer.tofaDeviceWaiting,
      TofaDeviceSignInStatus.unreachable => t.addServer.tofaDeviceUnreachable,
      TofaDeviceSignInStatus.approved => t.addServer.tofaDeviceSigningIn,
      TofaDeviceSignInStatus.expired => t.addServer.tofaDeviceExpired,
      TofaDeviceSignInStatus.denied => t.addServer.tofaDeviceDenied,
      TofaDeviceSignInStatus.failed => state.error ?? t.addServer.tofaDeviceFailed,
    };
  }

  Widget _buildDeviceCodePanel(ThemeData theme, TofaDeviceSignInState state) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final code = state.code;
    final live = !state.status.isSettled && code != null && !_completing;
    final settled = state.status.isSettled && state.status != TofaDeviceSignInStatus.approved;
    final working =
        _completing ||
        state.status == TofaDeviceSignInStatus.gettingCode ||
        state.status == TofaDeviceSignInStatus.approved;
    final displayUri = code?.verificationUri.replaceFirst(RegExp(r'^https?://'), '') ?? '';
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        Text(t.addServer.tofaSignInWithCode, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (live) ...[
          Text(
            t.addServer.tofaDeviceCodeInstructions(url: displayUri),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: muted),
          ),
          const SizedBox(height: 20),
          Semantics(
            label: t.addServer.tofaCodeSemantics(code: code.spokenCode),
            excludeSemantics: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                code.userCode,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: .bold,
                  letterSpacing: 6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.white,
              // A fixed size: the QR view cannot report intrinsic sizes.
              child: SizedBox.square(
                dimension: 168,
                child: QrImageView(
                  data: code.verificationUriComplete,
                  size: 168,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                  semanticsLabel: t.addServer.tofaQrSemantics(url: displayUri, code: code.spokenCode),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Semantics(
          liveRegion: true,
          child: Text(
            _statusText(state),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: settled ? theme.colorScheme.error : muted),
          ),
        ),
        if (working) ...[const SizedBox(height: 12), const Center(child: LoadingIndicatorBox(size: 20))],
        const SizedBox(height: 20),
        if (settled) ...[
          FocusableButton(
            focusNode: _newCodeFocus,
            useBackgroundFocus: true,
            onNavigateDown: () => _codeChangeServerFocus.requestFocus(),
            onPressed: () => unawaited(_startDeviceFlow()),
            child: FilledButton(
              onPressed: () => unawaited(_startDeviceFlow()),
              child: Text(t.addServer.tofaShowNewCode),
            ),
          ),
          const SizedBox(height: 12),
        ],
        FocusableButton(
          focusNode: _codeChangeServerFocus,
          useBackgroundFocus: true,
          onNavigateUp: settled ? () => _newCodeFocus.requestFocus() : null,
          onPressed: _completing ? null : _changeServer,
          child: TextButton.icon(
            onPressed: _completing ? null : _changeServer,
            icon: const AppIcon(Symbols.swap_horiz_rounded, fill: 1),
            label: Text(t.addServer.tofaChangeServer),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildProfileStep(ThemeData theme) {
    final tokensRef = tokens(context);
    return [
      Text(t.addServer.tofaChooseProfile, style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        t.addServer.tofaChooseProfileSubtitle,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
      ),
      const SizedBox(height: 16),
      for (final (i, profile) in _profiles.indexed) ...[
        if (i > 0) SizedBox(height: tokensRef.groupGap),
        _TofaProfileTile(
          profile: profile,
          autofocus: i == 0,
          borderRadius: groupItemRadii(context, i, _profiles.length),
          onTap: busy ? null : () => unawaited(_pickProfile(profile)),
        ),
      ],
      ...buildInlineError(theme),
      const SizedBox(height: 16),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusableButton(
          focusNode: _profileChangeServerFocus,
          useBackgroundFocus: true,
          onPressed: busy ? null : _changeServer,
          child: TextButton.icon(
            onPressed: busy ? null : _changeServer,
            icon: const AppIcon(Symbols.swap_horiz_rounded, fill: 1),
            label: Text(t.addServer.tofaChangeServer),
          ),
        ),
      ),
    ];
  }
}

class _TofaProfileTile extends StatelessWidget {
  final TofaProfile profile;
  final bool autofocus;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;

  const _TofaProfileTile({required this.profile, required this.autofocus, required this.borderRadius, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = profile.name.isEmpty ? '?' : profile.name.characters.first.toUpperCase();
    final states = [
      if (profile.isLocked) t.addServer.tofaProfileLocked,
      if (profile.isKids) t.addServer.tofaProfileKids,
    ];
    final tile = FocusableWrapper(
      autofocus: autofocus,
      disableScale: true,
      delegateFocusBorder: true,
      descendantsAreFocusable: false,
      onSelect: onTap,
      child: CardFocusBorder(
        borderRadii: borderRadius,
        strokeAlign: BorderSide.strokeAlignInside,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: borderRadius,
          child: InkWell(
            onTap: onTap,
            borderRadius: borderRadius,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // Initials only: whether avatar URLs need the bearer is
                  // unverified, and an image view cannot send it.
                  CircleAvatar(radius: 20, child: Text(initial)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      children: [
                        Text(profile.name, style: theme.textTheme.titleSmall),
                        if (profile.isKids)
                          Text(
                            t.addServer.tofaProfileKids,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (profile.isLocked) ...[
                    const AppIcon(Symbols.lock_rounded, fill: 1, size: 20),
                    const SizedBox(width: 8),
                  ],
                  const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: profile.name,
      value: states.isEmpty ? null : states.join(', '),
      enabled: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: tile,
    );
  }
}

/// A plain focusable row (a server of the account).
class _TofaChoiceTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget leading;
  final bool autofocus;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;

  const _TofaChoiceTile({
    required this.title,
    required this.leading,
    required this.autofocus,
    required this.borderRadius,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: title,
      value: subtitle,
      enabled: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: FocusableWrapper(
        autofocus: autofocus,
        disableScale: true,
        delegateFocusBorder: true,
        descendantsAreFocusable: false,
        onSelect: onTap,
        child: CardFocusBorder(
          borderRadii: borderRadius,
          strokeAlign: BorderSide.strokeAlignInside,
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: borderRadius,
            child: InkWell(
              onTap: onTap,
              borderRadius: borderRadius,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: .start,
                        children: [
                          Text(title, style: theme.textTheme.titleSmall),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
