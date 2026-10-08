import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
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
import '../../services/silo/silo_auth_service.dart';
import '../../services/storage_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../profile/pin_entry_dialog.dart';
import '../profile/profile_switch_screen.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';

/// Product name shown in the UI; not localized.
const _silo = 'Silo';

/// Add a Silo server:
///   1. Probe the address (`/api/v2/system/info`, https first, then http).
///   2. Sign in with a device code (approved on a phone or the web, Silo's
///      main TV flow) or with username and password.
///   3. Pick one of the account's Silo profiles, entering its PIN when it
///      has one. One account profile is one connection.
///   4. Persist the connection and bind it to [targetProfile] (or the active
///      Plezy profile), exactly as Jellyfin connections are.
class AddSiloScreen extends StatefulWidget {
  final Profile? targetProfile;

  const AddSiloScreen({super.key, this.targetProfile});

  @override
  State<AddSiloScreen> createState() => _AddSiloScreenState();
}

enum _Step { address, signIn, deviceCode, profile }

class _AddSiloScreenState extends State<AddSiloScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'AddSilo:Url');
  final _findServerFocus = FocusNode(debugLabel: 'AddSilo:FindServer');
  final _changeServerFocus = FocusNode(debugLabel: 'AddSilo:ChangeServer');
  final _usernameFocus = FocusNode(debugLabel: 'AddSilo:Username');
  final _passwordFocus = FocusNode(debugLabel: 'AddSilo:Password');
  final _signInFocus = FocusNode(debugLabel: 'AddSilo:SignIn');
  final _codeFocus = FocusNode(debugLabel: 'AddSilo:Code');
  final _cancelCodeFocus = FocusNode(debugLabel: 'AddSilo:CancelCode');
  final _formKey = GlobalKey<FormState>();

  _Step _step = _Step.address;
  SiloAuthService? _auth;
  SiloServerInfo? _server;
  SiloDeviceCode? _deviceCode;
  bool _deviceCodeOpened = false;
  int _deviceAttempt = 0;
  SiloSignIn? _signIn;
  List<SiloProfile> _profiles = const [];

  @override
  void dispose() {
    _cancelDeviceLogin();
    for (final node in [
      _urlFocus,
      _findServerFocus,
      _changeServerFocus,
      _usernameFocus,
      _passwordFocus,
      _signInFocus,
      _codeFocus,
      _cancelCodeFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<SiloAuthService> _authService() async {
    final existing = _auth;
    if (existing != null) return existing;
    final storage = await StorageService.getInstance();
    final deviceId = await storage.getOrCreateClientIdentifier();
    return _auth = SiloAuthService(deviceId: deviceId);
  }

  String _errorFor(Object e) {
    if (e is SiloServerUnsupportedException) return t.addServer.siloServerTooOld;
    if (e is MediaServerAuthException) return e.display ?? e.message;
    if (e is MediaServerUrlException) return t.addServer.enterMediaBrowserUrlError(product: _silo);
    if (e is MediaServerHttpException && e.statusCode != null) return t.addServer.siloNotASiloServer;
    return t.addServer.couldNotReachServer(error: e.toString());
  }

  // ---------------------------------------------------------------------------
  // Step 1: address
  // ---------------------------------------------------------------------------

  Future<void> _probe() async {
    if (_urlController.text.trim().isEmpty) {
      setErrorText(t.addServer.enterMediaBrowserUrlError(product: _silo));
      return;
    }
    final server = await runAsync<SiloServerInfo>(
      () async => (await _authService()).probe(_urlController.text),
      errorMapper: _errorFor,
    );
    if (server == null || !mounted) return;
    setState(() {
      _server = server;
      _urlController.text = server.baseUrl;
      _step = _Step.signIn;
    });
    // Typing a password with a remote is miserable; TVs go straight to a code.
    if (server.deviceLoginAvailable && (PlatformDetector.isTV() || !server.passwordLoginAvailable)) {
      await _startDeviceLogin();
    } else {
      requestFocusAfterFrame(server.passwordLoginAvailable ? _usernameFocus : _codeFocus);
    }
  }

  void _changeServer() {
    _cancelDeviceLogin();
    setState(() {
      _server = null;
      _signIn = null;
      _profiles = const [];
      _step = _Step.address;
    });
    setErrorText(null);
    requestFocusAfterFrame(_urlFocus);
  }

  // ---------------------------------------------------------------------------
  // Step 2: sign in
  // ---------------------------------------------------------------------------

  Future<void> _signInWithPassword() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final server = _server;
    if (server == null) return;
    final signIn = await runAsync<SiloSignIn>(
      () async => (await _authService()).signInWithPassword(
        server,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      ),
      errorMapper: (e) {
        if (e is MediaServerAuthException) return e.display ?? t.addServer.invalidCredentials;
        appLogger.e('Add Silo sign-in failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
    if (signIn != null && mounted) await _onSignedIn(signIn);
  }

  Future<void> _startDeviceLogin() async {
    final server = _server;
    if (server == null) return;
    if (busy) return;
    final attempt = ++_deviceAttempt;
    setErrorText(null);
    // Busy until the code is on screen, so a password sign-in cannot start
    // alongside it (the same guard Jellyfin's Quick Connect uses).
    setBusy(true);
    try {
      final auth = await _authService();
      var code = await auth.startDeviceLogin(server);
      if (!mounted || attempt != _deviceAttempt) {
        unawaited(auth.cancelDeviceLogin(server, code));
        return;
      }
      setState(() {
        _deviceCode = code;
        _deviceCodeOpened = false;
        _step = _Step.deviceCode;
      });
      setBusy(false);
      requestFocusAfterFrame(_cancelCodeFocus);

      var deadline = code.expiresAt;
      var delay = Duration.zero;
      var backoff = code.interval;
      // A request that keeps vanishing (a proxy mangling the poll, a server
      // answering an unknown status) must not spin start/poll forever.
      var remints = 0;
      while (mounted && attempt == _deviceAttempt) {
        await Future<void>.delayed(delay);
        if (!mounted || attempt != _deviceAttempt) return;
        if (DateTime.now().isAfter(deadline)) {
          unawaited(auth.cancelDeviceLogin(server, code));
          _deviceFailed(t.addServer.siloDeviceCodeExpired);
          return;
        }
        final SiloDevicePollResult result;
        try {
          result = await auth.pollDeviceLogin(server, code);
          backoff = code.interval;
        } on MediaServerHttpException catch (e) {
          // Network errors, 5xx and 429 back off up to 30 s.
          appLogger.d('Silo device poll failed; backing off', error: e.runtimeType);
          backoff = Duration(seconds: (backoff.inSeconds * 2).clamp(1, 30));
          delay = backoff;
          continue;
        }
        if (!mounted || attempt != _deviceAttempt) return;
        switch (result.status) {
          case SiloDevicePollStatus.pending:
            // Approver lookups can extend the request; apply the extension the
            // server reports relative to its own clock, so clock skew between
            // this device and the server cannot expire the code early.
            final extended = code.localExpiryFor(result.expiresAt);
            if (extended != null && extended.isAfter(deadline)) deadline = extended;
            if (result.opened != _deviceCodeOpened) setState(() => _deviceCodeOpened = result.opened);
            delay = result.pollAfter ?? code.interval;
          case SiloDevicePollStatus.approved:
            _deviceAttempt++;
            final signIn = await runAsync<SiloSignIn>(
              () => auth.completeDeviceLogin(server, result),
              errorMapper: (e) => t.addServer.siloDeviceCodeFailed(error: e.toString()),
            );
            if (signIn != null && mounted) await _onSignedIn(signIn);
            // Still on the code panel means a later step failed (account,
            // profiles, saving): leave the panel so the error and the form show.
            if (mounted && _step == _Step.deviceCode) _deviceFailed(errorText ?? t.addServer.siloDeviceCodeExpired);
            return;
          case SiloDevicePollStatus.gone:
            // The request vanished (consumed, denied, expired): mint a new code.
            if (++remints > 3) {
              _deviceFailed(t.addServer.siloDeviceCodeExpired);
              return;
            }
            code = await auth.startDeviceLogin(server);
            if (!mounted || attempt != _deviceAttempt) return;
            deadline = code.expiresAt;
            setState(() {
              _deviceCode = code;
              _deviceCodeOpened = false;
            });
            delay = code.interval;
        }
      }
    } catch (e, st) {
      appLogger.w('Silo device sign-in failed', error: e, stackTrace: st);
      if (mounted && attempt == _deviceAttempt) _deviceFailed(t.addServer.siloDeviceCodeFailed(error: e.toString()));
    } finally {
      if (mounted && _step != _Step.deviceCode) setBusy(false);
    }
  }

  void _deviceFailed(String message) {
    if (!mounted) return;
    setState(() {
      _deviceCode = null;
      _step = _Step.signIn;
    });
    setErrorText(message);
    _focusSignInStep();
  }

  void _focusSignInStep() {
    final server = _server;
    if (server == null) return;
    requestFocusAfterFrame(
      server.deviceLoginAvailable ? _codeFocus : (server.passwordLoginAvailable ? _usernameFocus : _changeServerFocus),
    );
  }

  void _cancelDeviceLogin() {
    _deviceAttempt++;
    final server = _server;
    final code = _deviceCode;
    final auth = _auth;
    _deviceCode = null;
    if (server != null && code != null && auth != null) unawaited(auth.cancelDeviceLogin(server, code));
  }

  void _onCancelDeviceCode() {
    _cancelDeviceLogin();
    setState(() => _step = _Step.signIn);
    requestFocusAfterFrame(_server?.passwordLoginAvailable == true ? _usernameFocus : _codeFocus);
  }

  // ---------------------------------------------------------------------------
  // Step 3: profile
  // ---------------------------------------------------------------------------

  Future<void> _onSignedIn(SiloSignIn signIn) async {
    final profiles = await runAsync<List<SiloProfile>>(
      () async => (await _authService()).fetchProfiles(signIn),
      errorMapper: (e) => t.addServer.signInFailed(error: e.toString()),
    );
    if (profiles == null || !mounted) return;
    if (profiles.isEmpty) {
      setState(() => _step = _Step.signIn);
      setErrorText(t.addServer.siloNoProfiles);
      _focusSignInStep();
      return;
    }
    _signIn = signIn;
    // An approval bound to a profile, or a lone unlocked profile, needs no picker.
    final preset = profiles.where((p) => p.id == signIn.presetProfileId).firstOrNull;
    if (preset != null && signIn.presetProfileToken != null) {
      await _finish(preset, profileToken: signIn.presetProfileToken);
      return;
    }
    if (profiles.length == 1 && !profiles.single.hasPin) {
      await _finish(profiles.single);
      return;
    }
    setState(() {
      _profiles = profiles;
      _step = _Step.profile;
    });
  }

  Future<void> _pickProfile(SiloProfile profile) async {
    if (busy) return;
    final signIn = _signIn;
    if (signIn == null) return;
    String? profileToken;
    if (profile.hasPin) {
      String? error;
      while (true) {
        final pin = await showPinEntryDialog(context, profile.name, errorMessage: error);
        if (pin == null || !mounted) return;
        final token = await runAsync<String?>(
          () async => (await _authService()).verifyPin(signIn, profile, pin),
          errorMapper: (e) => switch (e) {
            MediaServerAuthException(statusCode: 429) => t.addServer.siloTooManyPinAttempts,
            MediaServerAuthException(:final display?) => display,
            _ => t.profiles.failedToVerifyPin,
          },
        );
        if (!mounted) return;
        if (token != null) {
          profileToken = token;
          break;
        }
        if (errorText != null) return;
        error = t.profiles.incorrectPinTryAgain;
      }
    }
    await _finish(profile, profileToken: profileToken);
  }

  // ---------------------------------------------------------------------------
  // Step 4: persist and bind
  // ---------------------------------------------------------------------------

  Future<void> _finish(SiloProfile profile, {String? profileToken}) async {
    final signIn = _signIn;
    final auth = _auth;
    if (signIn == null || auth == null) return;
    final connection = auth.buildConnection(signIn, profile, profileToken: profileToken);
    await runAsync<void>(
      () => _persistAndExit(connection),
      errorMapper: (e) {
        appLogger.e('Add Silo failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
  }

  Future<void> _persistAndExit(SiloConnection connection) async {
    if (!mounted) return;
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return;
    final targetProfile = widget.targetProfile;
    var boundProfile = targetProfile ?? activeProvider.active;
    // Same first-run rules as a Jellyfin connection: with no target and no
    // active profile, pick an existing profile, or create the first one.
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

    Profile? firstRunProfile;
    if (targetProfile == null && boundProfile == null && !hasProfiles) {
      final now = DateTime.now();
      firstRunProfile = Profile.local(
        id: 'local-${const Uuid().v4()}',
        displayName: connection.profileName.isNotEmpty ? connection.profileName : connection.serverName,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
      );
      boundProfile = firstRunProfile;
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
        userToken: connection.accessToken,
        userIdentifier: connection.userId,
        tokenAcquiredAt: DateTime.now(),
      ),
      firstRunProfile: firstRunProfile,
    );

    final boundToActive = bindProfile.id == activeProvider.activeId;
    if (!mounted) return;
    if (boundToActive) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.addServer.addMediaBrowserTitle(product: _silo)),
      slivers: [
        if (_step == _Step.deviceCode && _deviceCode != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: .fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
              child: Center(child: _buildDeviceCodePanel(theme, _deviceCode!)),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: .stretch,
                  children: _step == _Step.profile ? _buildProfileStep(theme) : _buildFormStep(theme),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildFormStep(ThemeData theme) {
    final server = _server;
    return [
      if (server == null) ...[
        FocusableTextFormField(
          controller: _urlController,
          focusNode: _urlFocus,
          tvTextInputPresentation: TvTextInputPresentation.platform,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          onNavigateDown: () => _findServerFocus.requestFocus(),
          textInputAction: TextInputAction.go,
          onFieldSubmitted: busy ? null : (_) => _probe(),
          decoration: InputDecoration(
            labelText: t.addServer.serverUrl,
            // URL example — intentionally not localized.
            hintText: 'https://silo.example.com',
            prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
          ),
          validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
        ),
        const SizedBox(height: 16),
        FocusableButton(
          focusNode: _findServerFocus,
          useBackgroundFocus: true,
          onNavigateUp: () => _urlFocus.requestFocus(),
          onPressed: busy ? null : _probe,
          child: FilledButton.icon(
            onPressed: busy ? null : _probe,
            icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.travel_explore_rounded, fill: 1),
            label: Text(t.addServer.findServer),
          ),
        ),
      ] else ...[
        _buildServerCard(theme, server),
        if (server.deviceLoginAvailable) ...[
          const SizedBox(height: 16),
          FocusableButton(
            focusNode: _codeFocus,
            useBackgroundFocus: true,
            onNavigateUp: () => _changeServerFocus.requestFocus(),
            onNavigateDown: server.passwordLoginAvailable ? () => _usernameFocus.requestFocus() : null,
            onPressed: busy ? null : _startDeviceLogin,
            child: FilledButton.tonalIcon(
              onPressed: busy ? null : _startDeviceLogin,
              icon: const AppIcon(Symbols.qr_code_2_rounded, fill: 1),
              label: Text(t.addServer.siloSignInWithCode),
            ),
          ),
        ],
        if (server.passwordLoginAvailable) ...[
          const SizedBox(height: 16),
          FocusableTextFormField(
            controller: _usernameController,
            focusNode: _usernameFocus,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !busy,
            onNavigateUp: () => (server.deviceLoginAvailable ? _codeFocus : _changeServerFocus).requestFocus(),
            textInputAction: TextInputAction.next,
            onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
            decoration: InputDecoration(
              labelText: t.addServer.username,
              prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
            ),
            validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
          ),
          const SizedBox(height: 12),
          FocusableTextFormField(
            controller: _passwordController,
            focusNode: _passwordFocus,
            obscureText: true,
            enabled: !busy,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: busy ? null : (_) => _signInWithPassword(),
            decoration: InputDecoration(
              labelText: t.addServer.password,
              prefixIcon: const AppIcon(Symbols.lock_rounded, fill: 1),
            ),
          ),
          const SizedBox(height: 16),
          FocusableButton(
            focusNode: _signInFocus,
            useBackgroundFocus: true,
            onPressed: busy ? null : _signInWithPassword,
            child: FilledButton.icon(
              onPressed: busy ? null : _signInWithPassword,
              icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
              label: Text(t.addServer.signIn),
            ),
          ),
        ] else if (!server.deviceLoginAvailable) ...[
          const SizedBox(height: 16),
          Text(t.addServer.siloPasswordLoginDisabled, style: theme.textTheme.bodyMedium),
        ],
      ],
      ...buildInlineError(theme),
    ];
  }

  Widget _buildServerCard(ThemeData theme, SiloServerInfo server) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      ),
      child: Row(
        children: [
          const AppIcon(Symbols.cloud_done_rounded, fill: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Text(server.serverName, style: theme.textTheme.titleSmall),
                Text(
                  [_silo, ?server.serverVersion, server.baseUrl].join(' · '),
                  maxLines: 1,
                  overflow: .ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          FocusableButton(
            focusNode: _changeServerFocus,
            useBackgroundFocus: true,
            onNavigateDown: () => (server.deviceLoginAvailable ? _codeFocus : _usernameFocus).requestFocus(),
            onPressed: busy ? null : _changeServer,
            child: TextButton(onPressed: busy ? null : _changeServer, child: Text(t.addServer.change)),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCodePanel(ThemeData theme, SiloDeviceCode code) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final verificationUri = code.verificationUri;
    final displayUri = verificationUri.replaceFirst(RegExp(r'^https?://'), '');
    final qrData = code.verificationUriComplete ?? verificationUri;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: .min,
        children: [
          Text(
            t.addServer.siloDeviceCodeInstructions(url: displayUri),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: muted),
          ),
          const SizedBox(height: 24),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                code.displayCode,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: .bold,
                  letterSpacing: 8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.white,
            child: QrImageView(data: qrData, size: 168, version: QrVersions.auto, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisSize: .min,
            children: [
              const LoadingIndicatorBox(size: 16),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _deviceCodeOpened ? t.addServer.siloDeviceCodeOpened : t.auth.quickConnectWaiting,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FocusableButton(
            focusNode: _cancelCodeFocus,
            useBackgroundFocus: true,
            onPressed: _onCancelDeviceCode,
            child: OutlinedButton.icon(
              onPressed: _onCancelDeviceCode,
              icon: const AppIcon(Symbols.close_rounded, fill: 1),
              label: Text(t.auth.quickConnectCancel),
            ),
          ),
          ...buildInlineError(theme, center: true),
        ],
      ),
    );
  }

  List<Widget> _buildProfileStep(ThemeData theme) {
    final tokensRef = tokens(context);
    return [
      Text(t.addServer.siloChooseProfile, style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        t.addServer.siloChooseProfileSubtitle,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
      ),
      const SizedBox(height: 16),
      for (final (i, profile) in _profiles.indexed) ...[
        if (i > 0) SizedBox(height: tokensRef.groupGap),
        _SiloProfileTile(
          profile: profile,
          autofocus: i == 0,
          borderRadius: groupItemRadii(context, i, _profiles.length),
          onTap: busy ? null : () => unawaited(_pickProfile(profile)),
        ),
      ],
      ...buildInlineError(theme),
    ];
  }
}

class _SiloProfileTile extends StatelessWidget {
  final SiloProfile profile;
  final bool autofocus;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;

  const _SiloProfileTile({required this.profile, required this.autofocus, required this.borderRadius, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = profile.avatarUrl;
    final initial = profile.name.isEmpty ? '?' : profile.name.characters.first.toUpperCase();
    return FocusableWrapper(
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
                  CircleAvatar(
                    radius: 20,
                    child: avatar == null
                        ? Text(initial)
                        : ClipOval(
                            child: Image.network(
                              avatar,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              // An expired or refused avatar URL falls back to the initial.
                              errorBuilder: (_, _, _) => Center(child: Text(initial)),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(profile.name, style: theme.textTheme.titleSmall)),
                  if (profile.hasPin) ...[
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
  }
}
