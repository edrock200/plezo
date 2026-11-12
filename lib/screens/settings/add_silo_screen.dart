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
import '../../profiles/silo_accounts.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/multi_server_manager.dart';
import '../../services/silo/pairing/silo_pairing_flow.dart';
import '../../services/silo/pairing/silo_pairing_host.dart';
import '../../services/silo/pairing/silo_pairing_protocol.dart';
import '../../services/silo/pairing/silo_pairing_receiver.dart';
import '../../services/silo/silo_api.dart';
import '../../services/silo/silo_auth_service.dart';
import '../../services/silo/silo_connection_edit.dart';
import '../../services/silo/silo_device_sign_in.dart';
import '../../services/silo/silo_password_change.dart';
import '../../services/storage_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../../utils/dialogs.dart';
import '../../utils/error_message_utils.dart';
import '../../utils/layout_constants.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../profile/pin_entry_dialog.dart';
import '../profile/profile_switch_screen.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';
import 'silo_password_change_panel.dart';

part 'add_silo_screen_edit.dart';

/// Product name shown in the UI; not localized.
const _silo = 'Silo';

/// Add a Silo server:
///   1. Probe the address (`/api/v2/system/info`, https first, then http).
///   2. Sign in with a device code (approved on a phone or the web, Silo's
///      main TV flow) or with username and password.
///   3. Pick one of the account's Silo profiles, entering its PIN when it
///      has one. One account profile is one connection. An account holding a
///      temporary password an admin set gets "Choose a new password" first
///      (TVs say where to change it instead, as Silo's TV apps do).
///   4. Persist the connection and bind it to [targetProfile] (or the active
///      Plezy profile), exactly as Jellyfin connections are.
///
/// On Android, while the address or code step is up, the device also
/// advertises itself to Silo's phone app on the LAN ("sign in from your
/// phone", [SiloPairingHost]): the phone pushes a server (address step) or
/// approves the code on screen (code step), after the person here allows it.
/// From the address step one phone session can sign in several accounts, on
/// any servers (Silo Android #810): each signs in with its own code and is
/// held until the session ends; then each picks its Silo profile in turn and
/// is saved with the usual rules (another account on a server the chosen
/// Plezilo profile already uses gets a new profile), and a summary names
/// where each went.
class AddSiloScreen extends StatefulWidget {
  final Profile? targetProfile;

  /// Test seam: the sign-in service to use instead of one built from storage.
  @visibleForTesting
  final SiloAuthService? authService;

  /// Test seam: device-code timings.
  @visibleForTesting
  final SiloDeviceSignInConfig deviceSignInConfig;

  /// Test seam: offer sign-in from a phone (default: on Android only).
  @visibleForTesting
  final bool? phoneSignIn;

  /// Test seam: the LAN advertiser (default: the Android platform channel).
  @visibleForTesting
  final SiloPairingAdvertiser? pairingAdvertiser;

  /// Test seam: called once the phone sign-in listener exists.
  @visibleForTesting
  final void Function(SiloPairingHost host)? onPairingHost;

  /// "Edit" / "Sign in again" on this saved connection instead of adding a
  /// server (see add_silo_screen_edit.dart). Pass the Plezilo profile it was
  /// opened from as [targetProfile].
  final SiloConnection? editConnection;

  /// With [editConnection]: check the saved address at once and go to the
  /// sign-in (the expired-session entry points), instead of opening at the
  /// address.
  final bool signInAgain;

  const AddSiloScreen({
    super.key,
    this.targetProfile,
    this.editConnection,
    this.signInAgain = false,
    this.authService,
    this.deviceSignInConfig = const SiloDeviceSignInConfig(),
    this.phoneSignIn,
    this.pairingAdvertiser,
    this.onPairingHost,
  });

  @override
  State<AddSiloScreen> createState() => _AddSiloScreenState();
}

enum _Step {
  address,
  signIn,
  deviceCode,
  profile,

  /// "Choose a new password" (phones, tablets, desktops).
  passwordChange,

  /// A TV's "change it on your phone or the web" message.
  passwordOnTv,

  /// Where the accounts of a phone session went (several, or one that failed).
  pairedSummary,

  /// Editing: another account or Silo profile signed in; where it goes.
  editConfirm,
}

/// One account of a finished phone session: saved into [profile], or not
/// added (null).
class _PairedOutcome {
  final String account;
  final String server;
  final String? profile;
  final bool newProfile;
  const _PairedOutcome({required this.account, required this.server, this.profile, this.newProfile = false});
}

/// Saving the accounts a phone session signed in, one after another.
class _PairedRun {
  _PairedRun(List<SiloSignIn> signIns) : queue = List.of(signIns), total = signIns.length;

  final List<SiloSignIn> queue;
  final int total;
  final List<_PairedOutcome> outcomes = [];

  /// One account and nothing else: it ends like any sign-in (saved and left).
  bool get single => total == 1;
}

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

/// Whether an HTTP [status] means the server (or a proxy in front of it) is
/// there but could not answer just now: 5xx, 408 and 429. Trying again later
/// may work, so it is not reported as "no Silo server here".
@visibleForTesting
bool siloIsTransientStatus(int status) => status >= 500 || status == 408 || status == 429;

/// The message for a sign-in step that failed for a reason other than a
/// refused password or an unusable server: a busy server, or a localized
/// reason (never the raw exception text).
@visibleForTesting
String siloSignInErrorMessage(Object error) => switch (error) {
  MediaServerHttpException(statusCode: final status?) when siloIsTransientStatus(status) => t.addServer.siloServerBusy,
  _ => t.addServer.signInFailed(error: localizedErrorReason(error)),
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
  final _tvSignOutFocus = FocusNode(debugLabel: 'AddSilo:TvSignOut');
  final _pairingPrimaryFocus = FocusNode(debugLabel: 'AddSilo:PairingPrimary');
  final _pairingSecondaryFocus = FocusNode(debugLabel: 'AddSilo:PairingSecondary');
  final _pairingCancelFocus = FocusNode(debugLabel: 'AddSilo:PairingCancel');
  final _pairedDoneFocus = FocusNode(debugLabel: 'AddSilo:PairedDone');
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

  /// "Choose a new password" for [_signIn], while it is open.
  SiloTemporaryPasswordSession? _passwordSession;
  SiloPasswordChangeController? _passwordChange;

  /// [_signIn] already replaced its temporary password and refreshed: a
  /// second refusal is not handed off again (it would loop).
  bool _passwordChanged = false;

  /// Sign in from a phone (Android): the LAN listener and its receiver.
  SiloPairingHost? _pairing;
  SiloPairingStatus _pairingStatus = const SiloPairingIdle();
  SiloPairingAdvertisement? _pairingAdvertised;
  bool _pairingSyncScheduled = false;

  /// The current device flow was started for a phone's `setup` push.
  bool _pairingSetupFlow = false;

  /// Completes when the current device flow's approval became a sign-in
  /// (true) or could not (false); a phone attempt relays it.
  Completer<bool>? _pairingApproval;

  /// Accounts the current phone session signed in (`setup`), held until the
  /// session ends; logged out if the screen is left first.
  final List<SiloSignIn> _pairedSignIns = [];

  /// The ended session's accounts being saved, one at a time.
  _PairedRun? _pairedRun;

  /// "Edit" / "Sign in again" ([AddSiloScreen.editConnection]).
  final _edit = _SiloEditState();

  void _setEditState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    _initEdit();
    if (widget.phoneSignIn ?? SiloPairingHost.supported) unawaited(_startPairing());
  }

  @override
  void dispose() {
    _completePairingApproval(false);
    final pairing = _pairing;
    _pairing = null;
    if (pairing != null) {
      pairing.receiver.status.removeListener(_onPairingStatus);
      unawaited(pairing.dispose());
    }
    _disposeDeviceFlow();
    _closePasswordChange();
    _discardSignIn();
    _discardPairedSignIns();
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
      _tvSignOutFocus,
      _pairingPrimaryFocus,
      _pairingSecondaryFocus,
      _pairingCancelFocus,
      _pairedDoneFocus,
    ]) {
      node.dispose();
    }
    _edit.dispose();
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
    MediaServerHttpException(statusCode: final status?) when siloIsTransientStatus(status) =>
      t.addServer.siloServerBusy,
    MediaServerHttpException(statusCode: _?) => t.addServer.siloNotASiloServer,
    _ => t.addServer.couldNotReachServer(error: localizedErrorReason(e)),
  };

  /// Log out a signed-in session that will not be saved.
  void _discardSignIn() {
    final signIn = _signIn;
    _signIn = null;
    final auth = _auth;
    if (signIn != null && !_handedOff && auth != null) unawaited(auth.logout(signIn.server, signIn.tokens));
  }

  /// Log out a phone session's accounts that were never saved.
  void _discardPairedSignIns() {
    final auth = _auth;
    final pending = [..._pairedSignIns, ...?_pairedRun?.queue];
    _pairedSignIns.clear();
    _pairedRun?.queue.clear();
    if (auth == null) return;
    for (final signIn in pending) {
      unawaited(auth.logout(signIn.server, signIn.tokens));
    }
  }

  // ---------------------------------------------------------------------------
  // Sign in from a phone (Silo companion pairing)
  // ---------------------------------------------------------------------------

  Future<void> _startPairing() async {
    final auth = await _authService();
    final identity = await DeviceIdentityService.resolve();
    if (!mounted) return;
    // The id Silo already knows this device by (X-Silo-Device-Id).
    final deviceId = auth.deviceId;
    final name = SiloPairingProtocol.fittedServiceName(identity.deviceName);
    final receiver = SiloPairingReceiver(
      port: _ScreenPairingPort(this),
      identityProbe: auth.probeIdentity,
      deviceName: name,
      deviceId: deviceId,
    );
    final host = SiloPairingHost(
      receiver: receiver,
      advertiser: widget.pairingAdvertiser ?? MethodChannelSiloPairingAdvertiser(),
      serviceName: name,
      deviceId: deviceId,
    );
    _pairing = host;
    receiver.status.addListener(_onPairingStatus);
    receiver.onSessionEnd = _onPairingSessionEnd;
    widget.onPairingHost?.call(host);
    _syncPairingAdvertisement();
  }

  /// What the current step advertises: `setup` on the address step, `login`
  /// for the server whose code is on screen, nothing elsewhere.
  SiloPairingAdvertisement? _wantedAdvertisement() {
    final server = _server;
    // Saving a finished session's accounts: no new phone meanwhile.
    if (_pairedRun != null) return null;
    return switch (_step) {
      // Editing signs in to one saved server: a phone approves the code on
      // screen (`login`), it does not push servers.
      _Step.address when widget.editConnection == null => SiloPairingAdvertisement.setup,
      _Step.deviceCode when server != null && !_completingApproval && server.serverId.isNotEmpty =>
        SiloPairingAdvertisement.login(server.serverId),
      _ => null,
    };
  }

  /// Keep the advertisement in step with the screen (after each frame, so
  /// every step change is covered without touching each setState).
  void _syncPairingAdvertisement() {
    final pairing = _pairing;
    if (pairing == null || !mounted) return;
    final wanted = _wantedAdvertisement();
    if (wanted == _pairingAdvertised) return;
    _pairingAdvertised = wanted;
    unawaited(pairing.advertise(wanted));
  }

  void _schedulePairingSync() {
    if (_pairing == null || _pairingSyncScheduled) return;
    _pairingSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pairingSyncScheduled = false;
      _syncPairingAdvertisement();
    });
  }

  /// Statuses that replace the screen's own content with the pairing panel.
  bool _pairingTakesOver(SiloPairingStatus status) => switch (status) {
    SiloPairingConsentRequested() || SiloPairingUnreachable() || SiloPairingFailed() => _pairedRun == null,
    SiloPairingConnected() || SiloPairingWorking() => _step != _Step.deviceCode,
    // Between the accounts of one session, and while the session ends.
    SiloPairingSignedIn() => _pairedSignIns.isNotEmpty && _step == _Step.address,
    SiloPairingCompleted() => _pairedRun != null && _step == _Step.address,
    _ => false,
  };

  void _onPairingStatus() {
    final pairing = _pairing;
    if (pairing == null || !mounted) return;
    final previous = _pairingStatus;
    final next = pairing.receiver.status.value;
    setState(() => _pairingStatus = next);
    final took = _pairingTakesOver(previous);
    final takes = _pairingTakesOver(next);
    if (takes && (!took || previous.runtimeType != next.runtimeType)) {
      requestFocusAfterFrame(switch (next) {
        SiloPairingConnected() || SiloPairingWorking() => _pairingCancelFocus,
        SiloPairingUnreachable(alternateUrl: null) => _pairingSecondaryFocus,
        _ => _pairingPrimaryFocus,
      });
    } else if (took && !takes) {
      _focusCurrentStep();
    }
  }

  void _focusCurrentStep() {
    switch (_step) {
      case _Step.address:
        requestFocusAfterFrame(_urlFocus);
      case _Step.deviceCode:
        requestFocusAfterFrame(_cancelCodeFocus);
      case _Step.signIn:
        _focusSignInStep();
      case _Step.pairedSummary:
        requestFocusAfterFrame(_pairedDoneFocus);
      case _Step.editConfirm:
        requestFocusAfterFrame(_edit.confirmFocus);
      case _Step.profile || _Step.passwordChange || _Step.passwordOnTv:
        break;
    }
  }

  void _completePairingApproval(bool signedIn) {
    final completer = _pairingApproval;
    _pairingApproval = null;
    if (completer != null && !completer.isCompleted) completer.complete(signedIn);
  }

  /// A phone pushed [target] and the person allowed it: check the server,
  /// start a device code there and return it once the server issued it. The
  /// code carries the session's [binding] where the server checks one.
  Future<SiloPairingCode> _pairingStartSetup(SiloPairingTarget target, {SiloDeviceLoginBinding? binding}) async {
    // Saving an earlier session's accounts: nothing new starts meanwhile.
    if (!mounted || _pairedRun != null || widget.editConnection != null) {
      throw const SiloPairingAttemptFailure(SiloPairingFailureCode.authFailed);
    }
    final auth = await _authService();
    final SiloServerInfo server;
    try {
      server = await auth.probe(target.url);
    } on SiloServerUnsupportedException {
      throw const SiloPairingAttemptFailure(SiloPairingFailureCode.updateRequired);
    } catch (e) {
      appLogger.i('[silo-pair] pushed server did not answer: ${e.runtimeType}');
      throw const SiloPairingAttemptFailure(SiloPairingFailureCode.unreachable);
    }
    final verified = target.verifiedServerId;
    if (verified != null && server.serverId != verified) {
      throw const SiloPairingAttemptFailure(SiloPairingFailureCode.identityMismatch);
    }
    if (!server.deviceLoginAvailable) throw const SiloPairingAttemptFailure(SiloPairingFailureCode.authFailed);
    if (!mounted) throw const SiloPairingAttemptFailure(SiloPairingFailureCode.authFailed);
    // Whatever the screen was doing, the person allowed this server instead.
    _disposeDeviceFlow();
    _closePasswordChange();
    _discardSignIn();
    setErrorText(null);
    setState(() {
      _server = server;
      _urlController.text = server.baseUrl;
      _profiles = const [];
      _completingApproval = false;
      _step = _Step.signIn;
    });
    final bound = siloSessionBindingFor(server, binding);
    appLogger.i(
      '[silo-pair] binding sent=${bound != null ? 'yes' : 'no reason=${server.deviceSessionBinding ? 'http' : 'no_session_binding'}'}',
    );
    await _startDeviceLogin(binding: bound);
    final flow = _deviceFlow;
    if (flow == null || !mounted) throw const SiloPairingAttemptFailure(SiloPairingFailureCode.authFailed);
    _pairingSetupFlow = true;
    return siloPairingFirstCode(flow.state);
  }

  /// `login`: the code on screen, waiting briefly while one is fetched.
  Future<SiloPairingCode?> _pairingCurrentCode() async {
    final flow = _deviceFlow;
    if (flow == null || _completingApproval) return null;
    try {
      return await siloPairingFirstCode(flow.state, timeout: const Duration(seconds: 10));
    } on SiloPairingAttemptFailure {
      return null;
    }
  }

  Future<SiloPairingFailureCode?> _pairingOutcome(String deviceCode) {
    final flow = _deviceFlow;
    if (flow == null) return Future.value(SiloPairingFailureCode.expired);
    final approval = _pairingApproval ??= Completer<bool>();
    return siloPairingOutcome(flow.state, deviceCode, approval.future);
  }

  /// The phone's `setup` attempt ended without a sign-in: leave its code.
  void _pairingAbandonSetup(String? deviceCode) {
    if (!mounted || !_pairingSetupFlow || _completingApproval) return;
    final flow = _deviceFlow;
    if (deviceCode != null && flow != null && flow.code != null && flow.code!.deviceCode != deviceCode) return;
    if (_step != _Step.deviceCode) return;
    _changeServer();
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
    if (server == null || !mounted || !_editAcceptsServer(server)) return;
    // https is always tried first; only plain HTTP answered. Nothing is sent
    // with a credential until the person accepts that, as in Silo's apps.
    if (siloUsesPlainHttp(server.baseUrl)) {
      final accepted = await showConfirmDialog(
        context,
        title: t.reviewFixes.plainHttpTitle,
        message: t.reviewFixes.plainHttpMessage(server: siloHostLabel(server.baseUrl)),
        confirmText: t.reviewFixes.plainHttpConfirm,
      );
      if (!mounted) return;
      if (!accepted) {
        requestFocusAfterFrame(_urlFocus);
        return;
      }
    }
    setState(() {
      _server = server;
      _urlController.text = server.baseUrl;
      _step = _Step.signIn;
    });
    if (_editAddressPending) {
      // Editing, and the server moved: saving the address may be all it needs.
      requestFocusAfterFrame(_edit.saveAddressFocus);
    } else if (server.deviceLoginAvailable && (PlatformDetector.isTV() || !server.passwordLoginAvailable)) {
      // Typing a password with a remote is miserable; TVs go straight to a code.
      await _startDeviceLogin();
    } else {
      _focusSignInStep(preferPassword: true);
    }
  }

  void _changeServer() {
    _disposeDeviceFlow();
    _closePasswordChange();
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
        if (e is MediaServerAuthException) {
          return e.display ?? (e.statusCode == 429 ? t.addServer.siloServerBusy : t.addServer.invalidCredentials);
        }
        if (e is SiloSignInException) return _errorFor(e);
        appLogger.e('Add Silo sign-in failed', error: e);
        return siloSignInErrorMessage(e);
      },
    );
    if (signIn != null && mounted) await _onSignedIn(signIn);
  }

  Future<void> _startDeviceLogin({SiloDeviceLoginBinding? binding}) async {
    final server = _server;
    if (server == null || busy) return;
    setErrorText(null);
    final auth = await _authService();
    if (!mounted || !identical(server, _server)) return;
    _disposeDeviceFlow();
    final flow = SiloDeviceSignIn(auth: auth, server: server, config: widget.deviceSignInConfig, binding: binding);
    _pairingApproval = Completer<bool>();
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
      if (identical(flow, _deviceFlow)) _completePairingApproval(false);
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
    // A phone approving this code hears that this device is signed in; the
    // profile is picked here afterwards.
    if (_pairingSetupFlow && (_pairing?.receiver.hasSession ?? false)) {
      // One of possibly several accounts from this phone session: keep it
      // until the session ends, and wait for the phone's next push.
      _pairedSignIns.add(signIn);
      _completePairingApproval(true);
      _disposeDeviceFlow();
      setState(() {
        _server = null;
        _profiles = const [];
        _completingApproval = false;
        _step = _Step.address;
      });
      return;
    }
    _completePairingApproval(true);
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
      // Editing fills in the username: the password is what is left to type.
      target = widget.editConnection != null && _usernameController.text.isNotEmpty ? _passwordFocus : _usernameFocus;
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
    _pairingSetupFlow = false;
    _completePairingApproval(false);
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
    if (!identical(_signIn, signIn)) {
      _discardSignIn();
      _passwordChanged = false;
      // A new session is not saved yet: leaving must log it out.
      _handedOff = false;
    }
    _signIn = signIn;
    var passwordChangeRequired = false;
    final profiles = await runAsync<List<SiloProfile>>(
      () async => (await _authService()).fetchProfiles(signIn),
      errorMapper: (e) {
        if (e is SiloPasswordChangeRequiredException) {
          passwordChangeRequired = true;
          return '';
        }
        return e is SiloSignInException ? _errorFor(e) : siloSignInErrorMessage(e);
      },
    );
    if (!mounted) return;
    if (passwordChangeRequired && identical(_signIn, signIn) && !_passwordChanged) {
      setErrorText(null);
      await _openPasswordChange(signIn);
      return;
    }
    if (passwordChangeRequired) setErrorText(t.addServer.siloDeviceCouldntFinish);
    if ((profiles == null || profiles.isEmpty) && _pairedRun != null) {
      // One of a phone session's accounts: note it and go on with the next.
      _pairedNotAdded(signIn);
      return;
    }
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
  // Temporary password (Silo Android #790)
  // ---------------------------------------------------------------------------

  /// The account holds a temporary password, so the server refuses its
  /// profiles until it is replaced. Phones, tablets and desktops choose a new
  /// one here; a TV says where to change it, with Sign out focused.
  Future<void> _openPasswordChange(SiloSignIn signIn) async {
    _disposeDeviceFlow();
    _closePasswordChange();
    if (PlatformDetector.isTV()) {
      setState(() {
        _completingApproval = false;
        _step = _Step.passwordOnTv;
      });
      requestFocusAfterFrame(_tvSignOutFocus);
      return;
    }
    final auth = await _authService();
    if (!mounted || !identical(_signIn, signIn)) return;
    // A rotated pair is written back to signIn, so leaving logs out the live
    // session and the profiles are read with it.
    final session = await auth.temporaryPasswordSession(signIn);
    if (!mounted || !identical(_signIn, signIn)) {
      session.close();
      return;
    }
    final controller = SiloPasswordChangeController(session);
    controller.addListener(() => _onPasswordChangeState(controller));
    _passwordSession = session;
    _passwordChange = controller;
    setState(() {
      _completingApproval = false;
      _step = _Step.passwordChange;
    });
    unawaited(controller.load());
  }

  void _onPasswordChangeState(SiloPasswordChangeController controller) {
    if (!mounted || !identical(controller, _passwordChange) || !controller.value.finished) return;
    final signIn = _signIn;
    // The session no longer carries the restriction: on to the profiles.
    _closePasswordChange();
    if (signIn == null) return;
    _passwordChanged = true;
    unawaited(_onSignedIn(signIn));
  }

  void _closePasswordChange() {
    final controller = _passwordChange;
    final session = _passwordSession;
    _passwordChange = null;
    _passwordSession = null;
    // After this frame: the panel may still be listening while it unmounts.
    if (controller != null) WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    session?.close();
  }

  /// "Sign out" from the temporary-password step: ends this sign-in and goes
  /// back to the sign-in methods.
  void _signOutTemporaryPassword() {
    _closePasswordChange();
    final signIn = _signIn;
    if (_pairedRun != null && signIn != null) {
      _pairedNotAdded(signIn);
      return;
    }
    _discardSignIn();
    _passwordController.clear();
    setState(() => _step = _Step.signIn);
    setErrorText(null);
    _focusSignInStep(preferPassword: true);
  }

  List<Widget> _buildPasswordOnTvStep(ThemeData theme) => [
    Semantics(header: true, child: Text(t.addServer.siloPasswordChangeTitle, style: theme.textTheme.titleLarge)),
    const SizedBox(height: 8),
    Semantics(liveRegion: true, child: Text(t.addServer.siloPasswordResetOnTv, style: theme.textTheme.bodyLarge)),
    const SizedBox(height: 24),
    Align(
      alignment: AlignmentDirectional.centerStart,
      child: FocusableButton(
        focusNode: _tvSignOutFocus,
        autofocus: true,
        useBackgroundFocus: true,
        onPressed: _signOutTemporaryPassword,
        child: FilledButton.icon(
          onPressed: _signOutTemporaryPassword,
          icon: const AppIcon(Symbols.logout_rounded, fill: 1),
          label: Text(t.addServer.siloSignOut),
        ),
      ),
    ),
  ];

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
    if (widget.editConnection case final edited?) return _finishEdit(edited, connection);
    var saved = false;
    await runAsync<void>(
      () async => saved = await _persistAndExit(connection),
      errorMapper: (e) {
        appLogger.e('Add Silo failed', error: e);
        return siloSignInErrorMessage(e);
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

    final registry = context.read<ConnectionRegistry>();
    // This account and Silo profile may be saved already, with another
    // session: that one is revoked once the new one is stored.
    final prior = await registry.get(connection.id).catchError((_) => null);
    if (!mounted) return false;
    final replaced = prior is SiloConnection && prior.refreshToken != connection.refreshToken ? prior : null;
    final auth = _auth;
    final replacedEditor = replaced != null && auth != null ? _editor(auth) : null;
    // One Plezilo profile uses one account per Silo server (one active client
    // per server). Another account on a server the chosen profile already
    // uses gets a profile of its own, so both keep working; the active
    // profile stays as it is.
    var separateProfile = false;
    if (firstRunProfile == null && boundProfile != null) {
      final joinRows = await context.read<ProfileConnectionRegistry>().listForProfile(boundProfile.id);
      final connectionsById = {for (final c in await registry.list()) c.id: c};
      if (!mounted) return false;
      final other = otherSiloConnectionOnServer(
        incoming: connection,
        joinRows: joinRows,
        connectionsById: connectionsById,
      );
      if (other != null) {
        appLogger.i('Silo: ${boundProfile.displayName} already uses another account on this server; new profile');
        final now = DateTime.now();
        firstRunProfile = Profile.local(
          id: 'local-${const Uuid().v4()}',
          displayName: newProfileNameForSiloConnection(connection, activeProvider.profiles.map((p) => p.displayName)),
          sortOrder: now.millisecondsSinceEpoch,
          createdAt: now,
        );
        boundProfile = firstRunProfile;
        separateProfile = true;
      }
    }

    final bindProfile = boundProfile;
    if (bindProfile == null) {
      setErrorText(t.messages.noProfilesAvailable);
      return false;
    }

    // From here the session belongs to the saved connection: leaving must
    // not log it out.
    _handedOff = true;
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
        activateFirstRunProfile: !separateProfile,
      );
    } catch (_) {
      // The save is one transaction: when it did not commit, the session is
      // still ours to log out on leaving. A row saved earlier for this
      // account and Silo profile holds another session, so only a stored
      // copy of this session's refresh token counts.
      final stored = await registry.get(connection.id).catchError((_) => null);
      _handedOff = stored is SiloConnection && stored.refreshToken == connection.refreshToken;
      rethrow;
    }
    if (replaced != null && replacedEditor != null) {
      // The live client of the replaced session can no longer write its
      // tokens over the new row (its refresh token is not the stored one);
      // removing it from the manager logs that session out.
      appLogger.i('Silo: ${connection.serverName} was saved with another session; revoking it');
      replacedEditor.revokeSession(replaced);
    }

    final run = _pairedRun;
    run?.outcomes.add(
      _PairedOutcome(
        account: siloAccountLabel(connection),
        server: connection.serverName,
        profile: bindProfile.displayName,
        newProfile: separateProfile,
      ),
    );
    // Several accounts from a phone: the summary names the new profiles.
    if (separateProfile && (run == null || run.single)) {
      showMainSnackBar(
        t.addServer.siloAddedAsNewProfile(account: siloAccountLabel(connection), profile: bindProfile.displayName),
        duration: AppDurations.snackBarLong,
      );
    }
    final boundToActive = bindProfile.id == activeProvider.activeId;
    if (!mounted) return true;
    if (boundToActive) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
    if (!mounted) return true;
    if (run != null && !run.single) {
      // After this save's busy state clears.
      Timer.run(_advancePairedRun);
      return true;
    }
    Navigator.of(context).pop(true);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Several accounts from one phone session (Silo Android #810)
  // ---------------------------------------------------------------------------

  /// The phone's session is over: save the accounts it signed in, first to
  /// last (Silo's TVs open the first).
  void _onPairingSessionEnd() {
    if (!mounted || _pairedRun != null || _pairedSignIns.isEmpty) return;
    appLogger.i('[silo-pair] saving ${_pairedSignIns.length} account(s) from the phone session');
    _pairedRun = _PairedRun(_pairedSignIns);
    _pairedSignIns.clear();
    _advancePairedRun();
  }

  /// The next account of [_pairedRun]: its profiles (picked automatically
  /// when the approval bound one or there is a single unlocked one), or the
  /// summary once none is left.
  void _advancePairedRun() {
    final run = _pairedRun;
    if (run == null || !mounted) return;
    if (busy) {
      Timer.run(_advancePairedRun);
      return;
    }
    if (run.queue.isEmpty) {
      setErrorText(null);
      setState(() {
        _server = null;
        _profiles = const [];
        _step = _Step.pairedSummary;
      });
      requestFocusAfterFrame(_pairedDoneFocus);
      return;
    }
    final next = run.queue.removeAt(0);
    setErrorText(null);
    setState(() {
      _server = next.server;
      _profiles = const [];
      _step = _Step.address;
    });
    unawaited(_onSignedIn(next));
  }

  /// [signIn] could not be saved (no profiles, a temporary password) or the
  /// person skipped it: log it out and go on.
  void _pairedNotAdded(SiloSignIn signIn) {
    _pairedRun?.outcomes.add(_PairedOutcome(account: signIn.account.username, server: signIn.server.serverName));
    if (identical(_signIn, signIn)) _discardSignIn();
    Timer.run(_advancePairedRun);
  }

  /// "Done" on the summary: leave when an account was saved, else back to
  /// the address step.
  void _closePairedSummary() {
    final run = _pairedRun;
    _pairedRun = null;
    if (run != null && run.outcomes.any((o) => o.profile != null)) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _step = _Step.address);
    requestFocusAfterFrame(_urlFocus);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _schedulePairingSync();
    final pairingPanel = _pairingTakesOver(_pairingStatus);
    return FocusedScrollScaffold(
      title: Text(switch (widget.editConnection) {
        final edited? => _editTitle(edited),
        null => t.addServer.addMediaBrowserTitle(product: _silo),
      }),
      slivers: [
        if (pairingPanel)
          SliverPadding(
            padding: const EdgeInsets.all(24),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _buildPairingPanel(theme, _pairingStatus),
                ),
              ),
            ),
          )
        else if (_step == _Step.deviceCode && _deviceState != null)
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
                  children: switch (_step) {
                    _Step.profile => _buildProfileStep(theme),
                    _Step.pairedSummary => _buildPairedSummary(theme),
                    _Step.editConfirm => _buildEditConfirm(theme),
                    _Step.passwordOnTv => _buildPasswordOnTvStep(theme),
                    _Step.passwordChange when _passwordChange != null => [
                      SiloPasswordChangePanel(controller: _passwordChange!, onSignOut: _signOutTemporaryPassword),
                    ],
                    _ => _buildFormStep(theme),
                  },
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
        ..._buildEditIntro(theme),
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
        if (_pairing != null && widget.editConnection == null) ...[const SizedBox(height: 24), _buildPhoneCard(theme)],
      ] else ...[
        _buildServerCard(theme, server),
        ..._buildEditAddressAction(theme, server),
        if (server.deviceLoginAvailable) ...[
          const SizedBox(height: 16),
          FocusableButton(
            focusNode: _codeFocus,
            useBackgroundFocus: true,
            onNavigateUp: () => (_editAddressFocus ?? _changeServerFocus).requestFocus(),
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
            onNavigateUp: () =>
                (server.deviceLoginAvailable ? _codeFocus : _editAddressFocus ?? _changeServerFocus).requestFocus(),
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
          AppIcon(
            siloUsesPlainHttp(server.baseUrl) ? Symbols.no_encryption_rounded : Symbols.cloud_done_rounded,
            fill: 1,
          ),
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
                if (siloUsesPlainHttp(server.baseUrl))
                  Text(
                    t.reviewFixes.plainHttpBadge,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
          FocusableButton(
            focusNode: _changeServerFocus,
            useBackgroundFocus: true,
            onNavigateDown: () =>
                (_editAddressFocus ?? (server.deviceLoginAvailable ? _codeFocus : _usernameFocus)).requestFocus(),
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
        if (_pairing != null && code != null) ...[
          const SizedBox(height: 16),
          Text(
            _pairingStatus is SiloPairingAwaitingApproval
                ? t.siloPairing.confirmOnPhone
                : t.siloPairing.codeHint(product: _silo),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
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

  Widget _buildPhoneCard(ThemeData theme) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final looking = _pairingStatus is SiloPairingAdvertising;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      ),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          const AppIcon(Symbols.smartphone_rounded, fill: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Text(t.siloPairing.phoneTitle, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  t.siloPairing.phoneBody(product: _silo),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                if (looking) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const LoadingIndicatorBox(size: 14),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(t.siloPairing.looking, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _pairingFailureText(SiloPairingFailed failed) {
    final server = failed.serverName;
    return switch (failed.code) {
      SiloPairingFailureCode.denied => t.siloPairing.failedDenied(server: server),
      SiloPairingFailureCode.expired => t.siloPairing.failedExpired(server: server),
      SiloPairingFailureCode.unreachable => t.siloPairing.failedUnreachable(server: server),
      SiloPairingFailureCode.identityMismatch =>
        failed.signIn
            ? t.siloPairing.failedIdentitySignIn(server: server)
            : t.siloPairing.failedIdentity(server: server),
      SiloPairingFailureCode.updateRequired => t.siloPairing.failedUpdate(server: server),
      SiloPairingFailureCode.authFailed ||
      SiloPairingFailureCode.limitReached => t.siloPairing.failedGeneric(server: server),
    };
  }

  Widget _pairingButton({
    required FocusNode focusNode,
    required String label,
    required VoidCallback onPressed,
    bool primary = false,
    FocusNode? up,
    FocusNode? down,
  }) {
    return FocusableButton(
      focusNode: focusNode,
      useBackgroundFocus: true,
      onNavigateUp: up == null ? null : () => up.requestFocus(),
      onNavigateDown: down == null ? null : () => down.requestFocus(),
      onPressed: onPressed,
      child: primary
          ? FilledButton(onPressed: onPressed, child: Text(label))
          : OutlinedButton(onPressed: onPressed, child: Text(label)),
    );
  }

  /// The phone sign-in panel: what the phone is doing, "Allow this setup?",
  /// an address that did not answer, or how the attempt ended.
  Widget _buildPairingPanel(ThemeData theme, SiloPairingStatus status) {
    final receiver = _pairing?.receiver;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    String title;
    final lines = <(String, bool)>[];
    final buttons = <Widget>[];
    var working = false;
    void cancelButton() => buttons.add(
      _pairingButton(
        focusNode: _pairingCancelFocus,
        label: t.siloPairing.cancel,
        onPressed: () => receiver?.cancelActiveSession(),
      ),
    );
    switch (status) {
      case SiloPairingConsentRequested(:final serverName, :final unencrypted, :final signIn):
        title = signIn ? t.siloPairing.consentTitleSignIn : t.siloPairing.consentTitle;
        lines.add((t.siloPairing.consentBody(server: serverName), false));
        if (unencrypted) lines.add((t.siloPairing.consentUnencrypted(server: serverName), true));
        lines.add((t.siloPairing.consentNote, false));
        buttons
          ..add(
            _pairingButton(
              focusNode: _pairingPrimaryFocus,
              label: t.siloPairing.allow,
              primary: true,
              down: _pairingSecondaryFocus,
              onPressed: () => receiver?.allowPendingServer(),
            ),
          )
          ..add(
            _pairingButton(
              focusNode: _pairingSecondaryFocus,
              label: t.siloPairing.dontAllow,
              up: _pairingPrimaryFocus,
              onPressed: () => receiver?.denyPendingServer(),
            ),
          );
      case SiloPairingUnreachable(:final serverUrl, :final serverName, :final providerName, :final alternateUrl):
        title = t.siloPairing.unreachableTitle(server: serverName);
        lines.add((
          providerName != null
              ? t.siloPairing.unreachableProvider(server: serverName, provider: providerName)
              : t.siloPairing.unreachablePublic(server: serverName, url: normalizeSiloPairingUrl(serverUrl)),
          false,
        ));
        if (alternateUrl != null) {
          buttons.add(
            _pairingButton(
              focusNode: _pairingPrimaryFocus,
              label: t.siloPairing.useAlternate(url: alternateUrl),
              primary: true,
              down: _pairingSecondaryFocus,
              onPressed: () => receiver?.useAlternateAddress(),
            ),
          );
        }
        buttons.add(
          _pairingButton(
            focusNode: _pairingSecondaryFocus,
            label: t.siloPairing.tryAgain,
            primary: alternateUrl == null,
            up: alternateUrl != null ? _pairingPrimaryFocus : null,
            down: _pairingCancelFocus,
            onPressed: () => receiver?.retryPushedAddress(),
          ),
        );
        buttons.add(
          _pairingButton(
            focusNode: _pairingCancelFocus,
            label: t.siloPairing.cancel,
            up: _pairingSecondaryFocus,
            onPressed: () => receiver?.cancelActiveSession(),
          ),
        );
      case SiloPairingFailed(:final signIn):
        title = signIn ? t.siloPairing.failedTitleSignIn : t.siloPairing.failedTitle;
        lines.add((_pairingFailureText(status), false));
        buttons.add(
          _pairingButton(
            focusNode: _pairingPrimaryFocus,
            label: t.siloPairing.ok,
            primary: true,
            onPressed: () => receiver?.cancelActiveSession(),
          ),
        );
      case SiloPairingWorking(:final serverName, :final accountName):
        title = accountName != null
            ? t.siloPairing.workingTitleAccount(account: accountName, server: serverName)
            : t.siloPairing.workingTitle(server: serverName);
        lines.add((t.siloPairing.workingBody, false));
        working = true;
        cancelButton();
      case SiloPairingSignedIn(:final serverName, :final count):
        title = count > 1 ? t.siloPairing.signedInCount(n: count) : t.siloPairing.signedInTitle;
        lines.add((t.siloPairing.signedInBody(server: serverName), false));
        buttons.add(
          _pairingButton(
            focusNode: _pairingPrimaryFocus,
            label: t.siloPairing.continueHere,
            primary: true,
            onPressed: () => receiver?.finishSession(),
          ),
        );
      case SiloPairingCompleted():
        title = t.siloPairing.completedTitle;
        lines.add((t.siloPairing.savingAccounts, false));
        working = true;
      case _:
        title = t.siloPairing.connectedTitle;
        lines.add((t.siloPairing.connectedBody, false));
        working = true;
        cancelButton();
    }
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        const Center(child: AppIcon(Symbols.smartphone_rounded, fill: 1, size: 40)),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        ),
        const SizedBox(height: 12),
        for (final (text, warning) in lines) ...[
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(color: warning ? theme.colorScheme.error : muted),
          ),
          const SizedBox(height: 8),
        ],
        if (working) ...[const SizedBox(height: 8), const Center(child: LoadingIndicatorBox(size: 20))],
        const SizedBox(height: 16),
        for (final (i, button) in buttons.indexed) ...[if (i > 0) const SizedBox(height: 12), button],
      ],
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
          // Editing: the connection's own Silo profile comes first to hand.
          autofocus: _profiles.any(_isEditedProfile) ? _isEditedProfile(profile) : i == 0,
          current: _isEditedProfile(profile),
          borderRadius: groupItemRadii(context, i, _profiles.length),
          onTap: busy ? null : () => unawaited(_pickProfile(profile)),
        ),
      ],
      ...buildInlineError(theme),
      const SizedBox(height: 16),
      // Leaving here logs out the session that was just signed in (one of a
      // phone session's accounts: skips it).
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusableButton(
          focusNode: _profileChangeServerFocus,
          useBackgroundFocus: true,
          onPressed: busy ? null : _leaveProfileStep,
          child: TextButton.icon(
            onPressed: busy ? null : _leaveProfileStep,
            icon: AppIcon(_pairedRun != null ? Symbols.skip_next_rounded : Symbols.swap_horiz_rounded, fill: 1),
            label: Text(_pairedRun != null ? t.siloPairing.skipAccount : t.addServer.siloChangeServer),
          ),
        ),
      ),
    ];
  }

  void _leaveProfileStep() {
    final signIn = _signIn;
    if (_pairedRun != null && signIn != null) {
      _pairedNotAdded(signIn);
    } else {
      _changeServer();
    }
  }

  /// Where a phone session's accounts went, with Done focused.
  List<Widget> _buildPairedSummary(ThemeData theme) {
    final outcomes = _pairedRun?.outcomes ?? const <_PairedOutcome>[];
    final added = outcomes.where((o) => o.profile != null).length;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return [
      Semantics(
        header: true,
        liveRegion: true,
        child: Text(
          added == 0 ? t.siloPairing.summaryNoneTitle : t.siloPairing.summaryTitle(n: added),
          style: theme.textTheme.titleLarge,
        ),
      ),
      const SizedBox(height: 12),
      for (final outcome in outcomes) ...[
        Row(
          crossAxisAlignment: .start,
          children: [
            AppIcon(
              outcome.profile != null ? Symbols.check_circle_rounded : Symbols.error_rounded,
              fill: 1,
              color: outcome.profile != null ? null : theme.colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                outcome.profile != null
                    ? (outcome.newProfile
                          ? t.siloPairing.summaryAddedNewProfile(
                              account: outcome.account,
                              server: outcome.server,
                              profile: outcome.profile!,
                            )
                          : t.siloPairing.summaryAdded(
                              account: outcome.account,
                              server: outcome.server,
                              profile: outcome.profile!,
                            ))
                    : t.siloPairing.summaryNotAdded(account: outcome.account, server: outcome.server),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
      if (outcomes.any((o) => o.newProfile)) ...[
        const SizedBox(height: 4),
        Text(t.siloPairing.summarySwitchHint, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
      ],
      const SizedBox(height: 24),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusableButton(
          focusNode: _pairedDoneFocus,
          autofocus: true,
          useBackgroundFocus: true,
          onPressed: _closePairedSummary,
          child: FilledButton(onPressed: _closePairedSummary, child: Text(t.siloPairing.done)),
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

  /// The Silo profile the edited connection uses.
  final bool current;

  const _SiloProfileTile({
    required this.profile,
    required this.autofocus,
    required this.borderRadius,
    this.onTap,
    this.current = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = profile.avatarUrl;
    final initial = profile.name.isEmpty ? '?' : profile.name.characters.first.toUpperCase();
    final states = [
      if (current) t.siloEditConnection.currentProfile,
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
                        if (current || profile.isChild)
                          Text(
                            [
                              if (current) t.siloEditConnection.currentProfile,
                              if (profile.isChild) t.addServer.siloProfileKids,
                            ].join(' · '),
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

/// The sign-in screen's side of a phone's pairing attempt.
class _ScreenPairingPort implements SiloPairingSignInPort {
  _ScreenPairingPort(this._state);

  final _AddSiloScreenState _state;

  @override
  Future<SiloPairingCode> startSetup(SiloPairingTarget target, {SiloDeviceLoginBinding? binding}) =>
      _state._pairingStartSetup(target, binding: binding);

  @override
  Future<SiloPairingCode?> currentCode() => _state._pairingCurrentCode();

  @override
  Future<SiloPairingFailureCode?> outcome(String deviceCode) => _state._pairingOutcome(deviceCode);

  @override
  void abandonSetup(String? deviceCode) => _state._pairingAbandonSetup(deviceCode);
}
