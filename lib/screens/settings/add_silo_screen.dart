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
import '../../services/silo/silo_auth_service.dart';
import '../../services/silo/silo_device_sign_in.dart';
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

  /// Test seam: the sign-in service to use instead of one built from storage.
  @visibleForTesting
  final SiloAuthService? authService;

  /// Test seam: device-code timings.
  @visibleForTesting
  final SiloDeviceSignInConfig deviceSignInConfig;

  const AddSiloScreen({
    super.key,
    this.targetProfile,
    this.authService,
    this.deviceSignInConfig = const SiloDeviceSignInConfig(),
  });

  @override
  State<AddSiloScreen> createState() => _AddSiloScreenState();
}

enum _Step { address, signIn, deviceCode, profile }

/// The message for a failed `verify-pin`, shown in the PIN dialog. A wrong PIN
/// is not an error (the service returns null); this covers rate limiting, a
/// refusal with the server's problem detail, and transport failures.
@visibleForTesting
String siloPinErrorMessage(Object error) => switch (error) {
  SiloSignInException(failure: SiloSignInFailure.pinRateLimited) => t.addServer.siloTooManyPinAttempts,
  SiloSignInException(failure: SiloSignInFailure.pinRefused, :final detail?) => detail,
  SiloSignInException() => t.profiles.failedToVerifyPin,
  MediaServerHttpException(statusCode: final status?) when status >= 500 => t.profiles.failedToVerifyPin,
  _ => t.addServer.siloPinNetworkError,
};

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
  final _codeActionFocus = FocusNode(debugLabel: 'AddSilo:CodeAction');
  final _cancelCodeFocus = FocusNode(debugLabel: 'AddSilo:CancelCode');
  final _profileChangeServerFocus = FocusNode(debugLabel: 'AddSilo:ProfileChangeServer');
  final _formKey = GlobalKey<FormState>();

  _Step _step = _Step.address;
  SiloAuthService? _auth;
  SiloServerInfo? _server;
  SiloDeviceSignIn? _deviceFlow;
  SiloDeviceSignInState? _deviceState;

  /// An approval arrived and the account and profiles are being read: the
  /// code is spent, so the panel offers no cancel.
  bool _completingApproval = false;

  /// A signed-in session not yet saved as a connection. Logged out when the
  /// person leaves or changes server, so no unused session stays live.
  SiloSignIn? _signIn;

  /// The session was handed to persistence: never log it out from here.
  bool _handedOff = false;
  List<SiloProfile> _profiles = const [];

  @override
  void dispose() {
    _disposeDeviceFlow();
    _discardSignIn();
    for (final node in [
      _urlFocus,
      _findServerFocus,
      _changeServerFocus,
      _usernameFocus,
      _passwordFocus,
      _signInFocus,
      _codeFocus,
      _codeActionFocus,
      _cancelCodeFocus,
      _profileChangeServerFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<SiloAuthService> _authService() async {
    final existing = _auth ?? widget.authService;
    if (existing != null) return _auth = existing;
    final storage = await StorageService.getInstance();
    final deviceId = await storage.getOrCreateClientIdentifier();
    return _auth ??= SiloAuthService(deviceId: deviceId);
  }

  String _errorFor(Object e) => switch (e) {
    SiloServerUnsupportedException(apiMajor: final version?) => t.addServer.siloApiVersionUnsupported(
      version: version.toString(),
    ),
    SiloServerUnsupportedException() => t.addServer.siloServerTooOld,
    SiloSignInException(failure: SiloSignInFailure.notSiloServer) => t.addServer.siloNotASiloServer,
    SiloSignInException(failure: SiloSignInFailure.missingAccount) => t.addServer.siloDeviceCouldntFinish,
    SiloSignInException() => t.addServer.siloUnreadableAnswer,
    MediaServerAuthException() => e.display ?? e.message,
    MediaServerUrlException() => t.addServer.enterMediaBrowserUrlError(product: _silo),
    MediaServerHttpException(statusCode: _?) => t.addServer.siloNotASiloServer,
    _ => t.addServer.couldNotReachServer(error: e.toString()),
  };

  /// Log out a signed-in session that will not be saved.
  void _discardSignIn() {
    final signIn = _signIn;
    _signIn = null;
    final auth = _auth;
    if (signIn != null && !_handedOff && auth != null) unawaited(auth.logout(signIn.server, signIn.tokens));
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
      _focusSignInStep(preferPassword: true);
    }
  }

  void _changeServer() {
    _disposeDeviceFlow();
    _discardSignIn();
    setState(() {
      _server = null;
      _profiles = const [];
      _completingApproval = false;
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
        if (e is SiloSignInException) return _errorFor(e);
        appLogger.e('Add Silo sign-in failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
    if (signIn != null && mounted) await _onSignedIn(signIn);
  }

  Future<void> _startDeviceLogin() async {
    final server = _server;
    if (server == null || busy) return;
    setErrorText(null);
    final auth = await _authService();
    if (!mounted || !identical(server, _server)) return;
    _disposeDeviceFlow();
    final flow = SiloDeviceSignIn(auth: auth, server: server, config: widget.deviceSignInConfig);
    _deviceFlow = flow;
    flow.state.addListener(() => _onDeviceState(flow));
    setState(() {
      _deviceState = flow.state.value;
      _completingApproval = false;
      _step = _Step.deviceCode;
    });
    requestFocusAfterFrame(_cancelCodeFocus);
    unawaited(flow.start());
  }

  /// "Show a new code" / "Try again" on the code panel.
  void _restartDeviceLogin() {
    final flow = _deviceFlow;
    if (flow == null || _completingApproval) return;
    setErrorText(null);
    unawaited(flow.start());
    requestFocusAfterFrame(_cancelCodeFocus);
  }

  void _onDeviceState(SiloDeviceSignIn flow) {
    if (!mounted || !identical(flow, _deviceFlow)) return;
    final state = flow.state.value;
    final previous = _deviceState?.status;
    setState(() => _deviceState = state);
    if (state.status == previous) return;
    final approval = state.approval;
    if (state.status == SiloDeviceSignInStatus.approved && approval != null) {
      unawaited(_completeApproval(flow, approval));
      return;
    }
    // A settled state's action ("Show a new code", "Try again") takes focus,
    // as on Silo's TV; when the action goes away under focus, Cancel takes it.
    final action = _deviceAction(state.status);
    if (state.status.isSettled && action != null) {
      requestFocusAfterFrame(_codeActionFocus);
    } else if (action == null && _codeActionFocus.hasFocus) {
      requestFocusAfterFrame(_cancelCodeFocus);
    }
  }

  Future<void> _completeApproval(SiloDeviceSignIn flow, SiloDevicePollResult approval) async {
    setState(() => _completingApproval = true);
    final auth = flow.auth;
    final server = flow.server;
    final SiloSignIn signIn;
    try {
      signIn = await auth.completeDeviceLogin(server, approval);
    } catch (e, st) {
      appLogger.w('Silo device sign-in could not finish', error: e, stackTrace: st);
      final tokens = approval.tokens;
      if (tokens != null) unawaited(auth.logout(server, tokens));
      if (mounted && identical(flow, _deviceFlow)) _deviceFailed(t.addServer.siloDeviceCouldntFinish);
      return;
    }
    if (!mounted || !identical(flow, _deviceFlow)) {
      // Left or changed server meanwhile: the session is nobody's.
      unawaited(auth.logout(server, signIn.tokens));
      return;
    }
    await _onSignedIn(signIn);
    // Still on the code panel means a later step failed (profiles, saving):
    // leave the panel so the error and the form show.
    if (mounted && _step == _Step.deviceCode) _deviceFailed(errorText ?? t.addServer.siloDeviceCouldntFinish);
  }

  void _deviceFailed(String message) {
    if (!mounted) return;
    _disposeDeviceFlow();
    setState(() {
      _completingApproval = false;
      _step = _Step.signIn;
    });
    setErrorText(message);
    _focusSignInStep();
  }

  void _focusSignInStep({bool preferPassword = false}) {
    final server = _server;
    if (server == null) return;
    final FocusNode target;
    if (preferPassword && server.passwordLoginAvailable) {
      target = _usernameFocus;
    } else if (server.deviceLoginAvailable) {
      target = _codeFocus;
    } else {
      target = server.passwordLoginAvailable ? _usernameFocus : _changeServerFocus;
    }
    requestFocusAfterFrame(target);
  }

  /// Stop the device-code flow; a code still live on the server is withdrawn.
  /// An approved code is already spent and is left alone.
  void _disposeDeviceFlow() {
    final flow = _deviceFlow;
    _deviceFlow = null;
    _deviceState = null;
    flow?.dispose();
  }

  void _onCancelDeviceCode() {
    if (_completingApproval) return;
    _disposeDeviceFlow();
    setState(() => _step = _Step.signIn);
    setErrorText(null);
    _focusSignInStep(preferPassword: true);
  }

  // ---------------------------------------------------------------------------
  // Step 3: profile
  // ---------------------------------------------------------------------------

  Future<void> _onSignedIn(SiloSignIn signIn) async {
    if (!identical(_signIn, signIn)) _discardSignIn();
    _signIn = signIn;
    final profiles = await runAsync<List<SiloProfile>>(
      () async => (await _authService()).fetchProfiles(signIn),
      errorMapper: (e) => e is SiloSignInException ? _errorFor(e) : t.addServer.signInFailed(error: e.toString()),
    );
    if (!mounted) return;
    if (profiles == null || profiles.isEmpty) {
      // Nothing to pick: this session will not be used.
      _discardSignIn();
      _disposeDeviceFlow();
      setState(() {
        _completingApproval = false;
        _step = _Step.signIn;
      });
      if (profiles != null) setErrorText(t.addServer.siloNoProfiles);
      _focusSignInStep();
      return;
    }
    // An approval bound to a profile, or a lone unlocked profile, needs no
    // picker. A bound profile that has a PIN but came without its token
    // opens straight at its PIN.
    final preset = profiles.where((p) => p.id == signIn.presetProfileId).firstOrNull;
    SiloProfile? autoPick;
    if (preset != null && (signIn.presetProfileToken != null || !preset.hasPin)) {
      autoPick = preset;
    } else if (preset == null && profiles.length == 1 && !profiles.single.hasPin) {
      autoPick = profiles.single;
    }
    if (autoPick != null &&
        await _finish(autoPick, profileToken: identical(autoPick, preset) ? signIn.presetProfileToken : null)) {
      return;
    }
    if (!mounted) return;
    // The picker, also when saving an automatic pick failed (its error shows).
    _disposeDeviceFlow();
    setState(() {
      _profiles = profiles;
      _completingApproval = false;
      _step = _Step.profile;
    });
    if (preset != null && preset.hasPin && autoPick == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _step == _Step.profile) unawaited(_pickProfile(preset));
      });
    }
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
        setErrorText(null);
        setBusy(true);
        String? token;
        try {
          token = await (await _authService()).verifyPin(signIn, profile, pin);
          error = token == null ? t.addServer.siloWrongPin : null;
        } catch (e) {
          appLogger.d('Silo PIN check failed', error: e.runtimeType);
          error = siloPinErrorMessage(e);
        } finally {
          setBusy(false);
        }
        if (!mounted || !identical(signIn, _signIn)) return;
        if (token != null) {
          profileToken = token;
          break;
        }
      }
    }
    await _finish(profile, profileToken: profileToken);
  }

  // ---------------------------------------------------------------------------
  // Step 4: persist and bind
  // ---------------------------------------------------------------------------

  /// Save the connection for [profile] and leave. False when saving failed
  /// (the error is shown) or the screen went away.
  Future<bool> _finish(SiloProfile profile, {String? profileToken}) async {
    final signIn = _signIn;
    final auth = _auth;
    if (signIn == null || auth == null) return false;
    final connection = auth.buildConnection(signIn, profile, profileToken: profileToken);
    var saved = false;
    await runAsync<void>(
      () async => saved = await _persistAndExit(connection),
      errorMapper: (e) {
        appLogger.e('Add Silo failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
    return saved;
  }

  Future<bool> _persistAndExit(SiloConnection connection) async {
    if (!mounted) return false;
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return false;
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
      if (!mounted) return false;
      boundProfile = activeProvider.active;
      if (boundProfile == null) {
        setErrorText(t.messages.noProfilesAvailable);
        return false;
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
      return false;
    }

    // From here the session belongs to the saved connection: leaving must
    // not log it out.
    _handedOff = true;
    final registry = context.read<ConnectionRegistry>();
    try {
      await persistAndBindConnection(
        context: context,
        connection: connection,
        bindToProfile: ProfileConnection(
          profileId: bindProfile.id,
          connectionId: connection.id,
          // The connection row holds Silo's rotating tokens; the join row keeps no copy.
          userToken: null,
          userIdentifier: connection.userId,
          tokenAcquiredAt: DateTime.now(),
        ),
        firstRunProfile: firstRunProfile,
      );
    } catch (_) {
      // The save is one transaction: when it did not commit, the session is
      // still ours to log out on leaving.
      _handedOff = await registry.get(connection.id).catchError((_) => null) != null;
      rethrow;
    }

    final boundToActive = bindProfile.id == activeProvider.activeId;
    if (!mounted) return true;
    if (boundToActive) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
    if (!mounted) return true;
    Navigator.of(context).pop(true);
    return true;
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
        if (_step == _Step.deviceCode && _deviceState != null)
          // Centred in the space left, scrolling when taller (a 540-high TV
          // with a status and two buttons). Real layout, not the intrinsic
          // sizes SliverFillRemaining needs (the QR view cannot give them).
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverToBoxAdapter(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.viewportMainAxisExtent - constraints.precedingScrollExtent).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Padding(
                  padding: .fromLTRB(24, 24, 24, 24 + MediaQuery.paddingOf(context).bottom),
                  child: Center(child: _buildDeviceCodePanel(theme, _deviceState!)),
                ),
              ),
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
          // Open the tvOS keyboard only when the field is selected, not as
          // the screen appears (as on the Jellyfin and Seerr screens).
          tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
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
          Text(t.addServer.siloNoSignInMethod, style: theme.textTheme.bodyMedium),
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

  /// The action a settled or struggling code panel offers, as on Silo's TV.
  String? _deviceAction(SiloDeviceSignInStatus status) => switch (status) {
    SiloDeviceSignInStatus.denied || SiloDeviceSignInStatus.paused => t.addServer.siloShowNewCode,
    SiloDeviceSignInStatus.failed ||
    SiloDeviceSignInStatus.unreachable ||
    SiloDeviceSignInStatus.tooManyRequests => t.addServer.siloTryAgain,
    _ => null,
  };

  String _deviceStatusText(SiloDeviceSignInStatus status) {
    final server = _server;
    final host = server == null ? _silo : (Uri.tryParse(server.baseUrl)?.host ?? server.serverName);
    return switch (status) {
      SiloDeviceSignInStatus.gettingCode => t.addServer.siloDeviceGettingCode,
      SiloDeviceSignInStatus.waiting => t.addServer.siloDeviceWaiting,
      SiloDeviceSignInStatus.opened => t.addServer.siloDeviceCodeOpened,
      SiloDeviceSignInStatus.newCode => t.addServer.siloDeviceNewCode,
      SiloDeviceSignInStatus.unreachable => t.addServer.siloDeviceUnreachable(server: host),
      SiloDeviceSignInStatus.tooManyRequests => t.addServer.siloDeviceTooManyRequests,
      SiloDeviceSignInStatus.approved => t.addServer.siloDeviceSigningIn,
      SiloDeviceSignInStatus.denied => t.addServer.siloDeviceDenied,
      SiloDeviceSignInStatus.paused => t.addServer.siloDevicePaused,
      SiloDeviceSignInStatus.noDeviceSignIn => t.addServer.siloDevicePasswordOnly,
      SiloDeviceSignInStatus.updateRequired => t.addServer.siloDeviceUpdateRequired,
      SiloDeviceSignInStatus.failed => t.addServer.siloDeviceFailed,
    };
  }

  Widget _buildDeviceCodePanel(ThemeData theme, SiloDeviceSignInState state) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final approving = _completingApproval || state.status == SiloDeviceSignInStatus.approved;
    final status = approving ? SiloDeviceSignInStatus.approved : state.status;
    final code = approving ? null : state.code;
    final working = !status.isSettled || approving;
    final problem = switch (status) {
      SiloDeviceSignInStatus.unreachable ||
      SiloDeviceSignInStatus.tooManyRequests ||
      SiloDeviceSignInStatus.denied ||
      SiloDeviceSignInStatus.noDeviceSignIn ||
      SiloDeviceSignInStatus.updateRequired ||
      SiloDeviceSignInStatus.failed => true,
      _ => false,
    };
    final action = approving ? null : _deviceAction(status);
    // Wide screens (TV, desktop, landscape tablets) put the QR beside the
    // code, as Silo's TV app does, so the panel fits a 540-high TV screen.
    final wide = code != null && MediaQuery.sizeOf(context).width >= 720;
    final details = Column(
      mainAxisSize: .min,
      children: [
        if (code != null) ..._buildCode(theme, code, muted),
        if (code != null && !wide) ...[_buildQr(code), const SizedBox(height: 24)],
        Row(
          mainAxisSize: .min,
          children: [
            if (working) ...[const LoadingIndicatorBox(size: 16), const SizedBox(width: 10)],
            Flexible(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _deviceStatusText(status),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: problem ? theme.colorScheme.error : muted),
                ),
              ),
            ),
          ],
        ),
        if (action != null) ...[
          const SizedBox(height: 24),
          FocusableButton(
            focusNode: _codeActionFocus,
            useBackgroundFocus: true,
            onNavigateDown: () => _cancelCodeFocus.requestFocus(),
            onPressed: _restartDeviceLogin,
            child: FilledButton.icon(
              onPressed: _restartDeviceLogin,
              icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
              label: Text(action),
            ),
          ),
        ],
        // An approved code is spent: nothing left to cancel.
        if (!approving) ...[
          SizedBox(height: action != null ? 12 : 24),
          FocusableButton(
            focusNode: _cancelCodeFocus,
            useBackgroundFocus: true,
            onNavigateUp: action != null ? () => _codeActionFocus.requestFocus() : null,
            onPressed: _onCancelDeviceCode,
            child: OutlinedButton.icon(
              onPressed: _onCancelDeviceCode,
              icon: const AppIcon(Symbols.close_rounded, fill: 1),
              label: Text(t.auth.quickConnectCancel),
            ),
          ),
        ],
        ...buildInlineError(theme, center: true),
      ],
    );
    if (!wide) return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: details);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Row(
        mainAxisSize: .min,
        children: [
          _buildQr(code),
          const SizedBox(width: 40),
          Flexible(child: details),
        ],
      ),
    );
  }

  List<Widget> _buildCode(ThemeData theme, SiloDeviceCode code, Color muted) {
    final verificationUri = code.verificationUri;
    final displayUri = verificationUri.replaceFirst(RegExp(r'^https?://'), '');
    final spoken = code.spokenCode;
    return [
      Text(
        t.addServer.siloDeviceCodeInstructions(url: displayUri),
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge?.copyWith(color: muted),
      ),
      const SizedBox(height: 24),
      // Read digit by digit, not as one large number.
      Semantics(
        label: t.addServer.siloCodeSemantics(code: spoken),
        excludeSemantics: true,
        child: FittedBox(
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
      ),
      const SizedBox(height: 24),
    ];
  }

  Widget _buildQr(SiloDeviceCode code) {
    final displayUri = code.verificationUri.replaceFirst(RegExp(r'^https?://'), '');
    final qrData = code.verificationUriComplete ?? code.verificationUri;
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.white,
      // A fixed size: the QR view is a LayoutBuilder, which cannot report
      // intrinsic sizes to an ancestor that asks for them.
      child: SizedBox.square(
        dimension: 168,
        child: QrImageView(
          data: qrData,
          size: 168,
          version: QrVersions.auto,
          backgroundColor: Colors.white,
          semanticsLabel: t.addServer.siloQrSemantics(url: displayUri, code: code.spokenCode),
        ),
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
      const SizedBox(height: 16),
      // Leaving here logs out the session that was just signed in.
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusableButton(
          focusNode: _profileChangeServerFocus,
          useBackgroundFocus: true,
          onPressed: busy ? null : _changeServer,
          child: TextButton.icon(
            onPressed: busy ? null : _changeServer,
            icon: const AppIcon(Symbols.swap_horiz_rounded, fill: 1),
            label: Text(t.addServer.siloChangeServer),
          ),
        ),
      ),
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
    final states = [
      if (profile.hasPin) t.addServer.siloProfilePinProtected,
      if (profile.isChild) t.addServer.siloProfileKids,
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      children: [
                        Text(profile.name, style: theme.textTheme.titleSmall),
                        if (profile.isChild)
                          Text(
                            t.addServer.siloProfileKids,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                      ],
                    ),
                  ),
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
    // One spoken element: the name, then "PIN protected" / "Kids profile".
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
