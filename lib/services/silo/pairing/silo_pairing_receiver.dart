import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../utils/app_logger.dart';
import '../silo_auth_service.dart';
import 'silo_pairing_protocol.dart';
import 'silo_pairing_transport.dart';

/// What `GET /api/v2/system/identity` said about one address.
sealed class SiloIdentityProbeResult {
  const SiloIdentityProbeResult();
}

/// The address answered with its deployment identity.
class SiloIdentityAnswer extends SiloIdentityProbeResult {
  final String serverId;
  const SiloIdentityAnswer(this.serverId);
}

/// The address answered but predates the identity contract (v1-only server).
class SiloIdentityUnsupported extends SiloIdentityProbeResult {
  const SiloIdentityUnsupported();
}

/// Nothing usable answered.
class SiloIdentityUnreachable extends SiloIdentityProbeResult {
  const SiloIdentityUnreachable();
}

typedef SiloIdentityProbe = Future<SiloIdentityProbeResult> Function(String serverUrl);

/// A device code the TV shows while the phone approves it.
@immutable
class SiloPairingCode {
  final String deviceCode;
  final String userCode;

  /// The server's `match_code`; the phone compares it with its own lookup.
  final String matchCode;

  const SiloPairingCode({required this.deviceCode, required this.userCode, required this.matchCode});
}

/// An attempt failed with a wire [code].
class SiloPairingAttemptFailure implements Exception {
  final SiloPairingFailureCode code;
  const SiloPairingAttemptFailure(this.code);

  @override
  String toString() => 'SiloPairingAttemptFailure(${code.wire})';
}

/// Where a `setup` attempt signs in: the address and the identity verified there.
@immutable
class SiloPairingTarget {
  final String url;
  final String? verifiedServerId;
  final String serverName;
  const SiloPairingTarget({required this.url, required this.serverName, this.verifiedServerId});
}

/// The sign-in screen's side of a pairing attempt.
abstract interface class SiloPairingSignInPort {
  /// `setup`: start device sign-in at [target] (the screen shows the code)
  /// and return the code once the server issued it. Throws
  /// [SiloPairingAttemptFailure]. [binding] is this phone session's binding;
  /// the screen sends it only where [siloSessionBindingFor] allows.
  Future<SiloPairingCode> startSetup(SiloPairingTarget target, {SiloDeviceLoginBinding? binding});

  /// `login`: the code the sign-in screen shows, waiting briefly while one is
  /// fetched; null when there is none.
  Future<SiloPairingCode?> currentCode();

  /// Completes when the request behind [deviceCode] signed in (null) or failed.
  Future<SiloPairingFailureCode?> outcome(String deviceCode);

  /// A `setup` attempt was abandoned (the phone left, cancelled or pushed
  /// another server; the TV user cancelled) before it finished: withdraw its
  /// code ([deviceCode], when one was issued) and leave the code screen.
  void abandonSetup(String? deviceCode);
}

/// What this device advertises (TXT `st`/`srv`, hello `state`).
@immutable
class SiloPairingAdvertisement {
  final SiloPairingReceiverState state;

  /// `login`: the identity (`server_id`) of the server on the sign-in screen.
  final String? serverIdentity;

  const SiloPairingAdvertisement._(this.state, this.serverIdentity);

  static const setup = SiloPairingAdvertisement._(SiloPairingReceiverState.setup, null);

  const SiloPairingAdvertisement.login(String serverIdentity) : this._(SiloPairingReceiverState.login, serverIdentity);

  /// TXT attributes besides `name`, `id` and `sid`. `setup` says `acct=1`
  /// (several accounts per session, Silo Android #810) and, like Silo's
  /// Android TV, no `lim`; the sign-in screen keeps one account.
  Map<String, String> txt() => {
    'v': '${SiloPairingProtocol.version}',
    'st': state.wire,
    if (state == SiloPairingReceiverState.setup) SiloPairingProtocol.txtAcceptsAccounts: '1',
    if (state == SiloPairingReceiverState.login && serverIdentity != null) 'srv': serverIdentity!,
  };

  @override
  bool operator ==(Object other) =>
      other is SiloPairingAdvertisement && other.state == state && other.serverIdentity == serverIdentity;

  @override
  int get hashCode => Object.hash(state, serverIdentity);
}

/// What the pairing panel shows. Mirrors Silo's `PairingReceiverStatus`.
sealed class SiloPairingStatus {
  const SiloPairingStatus();

  /// A phone holds the session (anything between connect and its end).
  bool get isSession => false;
}

/// Not advertising.
class SiloPairingIdle extends SiloPairingStatus {
  const SiloPairingIdle();
}

/// Advertising, waiting for a phone.
class SiloPairingAdvertising extends SiloPairingStatus {
  const SiloPairingAdvertising();
}

/// A phone connected and is choosing on its side.
class SiloPairingConnected extends SiloPairingStatus {
  const SiloPairingConnected();

  @override
  bool get isSession => true;
}

/// "Allow this setup?": the phone pushed a server; nothing starts until the
/// person here allows it. [unencrypted]: the address is plain HTTP.
class SiloPairingConsentRequested extends SiloPairingStatus {
  final String serverUrl;
  final String serverName;
  final bool unencrypted;
  final bool signIn;
  const SiloPairingConsentRequested({
    required this.serverUrl,
    required this.serverName,
    required this.unencrypted,
    required this.signIn,
  });

  @override
  bool get isSession => true;
}

/// Checking the address and getting a code. [accountName]: who the phone
/// says it will approve as (display only).
class SiloPairingWorking extends SiloPairingStatus {
  final String serverName;
  final String? accountName;
  const SiloPairingWorking(this.serverName, {this.accountName});

  @override
  bool get isSession => true;
}

/// The pushed address did not answer. [alternateUrl] is a verified address
/// of the same server the person may choose; nothing switches without that.
class SiloPairingUnreachable extends SiloPairingStatus {
  final String serverUrl;
  final String serverName;
  final String? providerName;
  final String? alternateUrl;
  const SiloPairingUnreachable({
    required this.serverUrl,
    required this.serverName,
    this.providerName,
    this.alternateUrl,
  });

  @override
  bool get isSession => true;
}

/// The code is on screen; the phone is approving it.
class SiloPairingAwaitingApproval extends SiloPairingStatus {
  final String serverName;
  final String userCode;
  const SiloPairingAwaitingApproval({required this.serverName, required this.userCode});

  @override
  bool get isSession => true;
}

/// A pushed account signed in ([count] so far this session); the phone may
/// push another or send `done`.
class SiloPairingSignedIn extends SiloPairingStatus {
  final String serverName;
  final int count;
  const SiloPairingSignedIn(this.serverName, {this.count = 1});

  @override
  bool get isSession => true;
}

/// The session ended after a sign-in.
class SiloPairingCompleted extends SiloPairingStatus {
  final List<String> serverNames;
  const SiloPairingCompleted(this.serverNames);
}

/// The last attempt failed; stays on screen until the person closes it.
class SiloPairingFailed extends SiloPairingStatus {
  final String serverName;
  final SiloPairingFailureCode code;
  final bool signIn;
  const SiloPairingFailed({required this.serverName, required this.code, required this.signIn});
}

class _AttemptCancelled implements Exception {
  const _AttemptCancelled();
}

class _Attempt {
  _Attempt(this.push, this.advertisement);

  final SiloPairingPushServer push;
  final SiloPairingAdvertisement advertisement;
  final Completer<void> _cancelled = Completer<void>();
  String? deviceCode;
  bool finished = false;

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// [future], or [_AttemptCancelled] as soon as the attempt is cancelled.
  Future<T> guard<T>(Future<T> future) async {
    if (isCancelled) throw const _AttemptCancelled();
    final result = await Future.any<Object?>([
      future.then<Object?>((value) => _Value(value)),
      _cancelled.future.then<Object?>((_) => const _AttemptCancelled()),
    ]);
    if (result is _Value) {
      if (isCancelled) throw const _AttemptCancelled();
      return result.value as T;
    }
    throw const _AttemptCancelled();
  }
}

class _Value {
  final Object? value;
  const _Value(this.value);
}

enum _AlternateChoice { useAlternate, retry }

/// The TV side of one phone connection: a port of silo-android
/// `PairingReceiver` (`android-shared/.../common/pairing/PairingReceiver.kt`).
///
/// 1. Send `hello` with the advertised state.
/// 2. On `pushServer`: ask the person here once per session ("Allow this
///    setup?", again for a plain-HTTP address). `setup`: check the pushed
///    identity at the pushed address (or offer a verified alternate), start
///    device sign-in there and send `deviceStarted`. `login`: the pushed
///    identity must be the advertised one; send the code already on screen.
///    Then `serverResult` once it signs in or fails. A newer push replaces
///    one in flight.
/// 3. `done` / `cancel` / EOF / error end the session.
///
/// `setup` (TXT `acct=1`, Silo Android #810): the phone may push again after
/// each sign-in, on any server, the same one included; each sign-in is its
/// own account, and a failed one does not end the session. Every device
/// login of a session carries that session's binding where the server
/// checks it ([SiloDeviceLoginBinding]). `login` signs in the one account
/// on screen: a later push answers `limit_reached`.
class SiloPairingReceiver {
  SiloPairingReceiver({
    required this.port,
    required this.identityProbe,
    required this.deviceName,
    required this.deviceId,
    this.idleTimeout = const Duration(seconds: 180),
    SiloDeviceLoginBinding Function()? newSessionBinding,
  }) : _newSessionBinding = newSessionBinding ?? SiloDeviceLoginBinding.generate;

  final SiloPairingSignInPort port;
  final SiloIdentityProbe identityProbe;
  final String deviceName;
  final String deviceId;

  /// A connected phone silent this long (nothing in flight) is dropped, so a
  /// phone that lost its network cannot hold the receiver (Silo: 180 s).
  final Duration idleTimeout;

  final ValueNotifier<SiloPairingStatus> status = ValueNotifier(const SiloPairingIdle());

  /// What is advertised; read when a session starts and a push arrives.
  SiloPairingAdvertisement advertisement = SiloPairingAdvertisement.setup;

  /// Called once a phone's session is over and the receiver is free again
  /// (after the end status is set). The screen saves the session's accounts.
  VoidCallback? onSessionEnd;

  final SiloDeviceLoginBinding Function() _newSessionBinding;

  /// This session's binding: every bound start and poll uses it.
  SiloDeviceLoginBinding? _sessionBinding;

  bool _listening = false;
  bool _disposed = false;
  SiloPairingTransport? _transport;
  SiloPairingPushServer? _pendingPush;
  bool _consented = false;
  bool _sessionDenied = false;
  final Set<String> _approvedHttpOrigins = {};
  _Attempt? _attempt;
  Completer<_AlternateChoice>? _alternateDecision;
  final List<String> _signedInNames = [];
  Timer? _idleTimer;
  bool _sessionClosing = false;

  /// A phone holds the receiver.
  bool get hasSession => _transport != null;

  void setAdvertising() {
    _listening = true;
    if (!hasSession && !_holdsTerminal) _set(const SiloPairingAdvertising());
  }

  void setIdle() {
    _listening = false;
    if (!hasSession && !_holdsTerminal) _set(const SiloPairingIdle());
  }

  bool get _holdsTerminal => status.value is SiloPairingFailed || status.value is SiloPairingCompleted;

  void _set(SiloPairingStatus value) {
    if (_disposed) return;
    status.value = value;
  }

  void _restingStatus() => _set(_listening ? const SiloPairingAdvertising() : const SiloPairingIdle());

  /// Accounts signed in during the current (or last) session.
  int get signedInCount => _signedInNames.length;

  /// "Continue" after a sign-in: end the session as if the phone sent `done`
  /// (the accounts signed in so far are kept).
  void finishSession() {
    final transport = _transport;
    if (transport == null || _signedInNames.isEmpty) return;
    appLogger.i('[silo-pair] finishing the session here');
    _cancelAttempt();
    _pendingPush = null;
    unawaited(transport.close());
  }

  /// Cancel / Back / OK on the pairing panel: end the session, or close a
  /// failure left on screen.
  void cancelActiveSession() {
    _attempt?.cancel();
    final transport = _transport;
    if (transport != null) unawaited(transport.close());
    _restingStatus();
  }

  /// The person allowed the pushed server.
  void allowPendingServer() {
    final push = _pendingPush;
    final transport = _transport;
    final consent = status.value;
    if (push == null || transport == null || consent is! SiloPairingConsentRequested) return;
    _consented = true;
    _pendingPush = null;
    if (consent.unencrypted) {
      final origin = _httpOrigin(push.serverUrl);
      if (origin != null) _approvedHttpOrigins.add(origin);
    }
    _beginAttempt(push, transport);
  }

  /// The person declined: the phone is told (`cancel consent_denied`) and the
  /// session ends.
  void denyPendingServer() {
    if (status.value is! SiloPairingConsentRequested) return;
    _sessionDenied = true;
    _pendingPush = null;
    final transport = _transport;
    if (transport != null) {
      unawaited(() async {
        try {
          await transport.send(const SiloPairingCancel('consent_denied'));
        } catch (_) {}
        await transport.close();
      }());
    }
    _restingStatus();
  }

  /// The person chose the verified alternate address offered while unreachable.
  void useAlternateAddress() {
    final current = status.value;
    if (current is! SiloPairingUnreachable || current.alternateUrl == null) return;
    final decision = _alternateDecision;
    if (decision != null && !decision.isCompleted) decision.complete(_AlternateChoice.useAlternate);
  }

  /// The person fixed the connection and wants the pushed address tried again.
  void retryPushedAddress() {
    if (status.value is! SiloPairingUnreachable) return;
    final decision = _alternateDecision;
    if (decision != null && !decision.isCompleted) decision.complete(_AlternateChoice.retry);
  }

  /// Drive one connection to its end. Always closes [transport]. A second
  /// connection while one is served is closed at once (one phone at a time).
  Future<void> run(SiloPairingTransport transport) async {
    if (_transport != null || _disposed) {
      await transport.close();
      return;
    }
    _transport = transport;
    _pendingPush = null;
    _consented = false;
    _sessionDenied = false;
    _sessionClosing = false;
    _approvedHttpOrigins.clear();
    _signedInNames.clear();
    _sessionBinding = _newSessionBinding();
    var preserveTerminal = false;
    try {
      await transport.send(SiloPairingHello(tvName: deviceName, tvDeviceId: deviceId, state: advertisement.state));
      _set(const SiloPairingConnected());
      appLogger.i('[silo-pair] phone connected; sent hello state=${advertisement.state.wire}');
      _armIdleTimer(transport);
      await for (final message in transport.incoming) {
        if (_attempt == null) _armIdleTimer(transport);
        switch (message) {
          case SiloPairingPushServer():
            _onPush(message, transport);
          case SiloPairingDone():
            appLogger.i('[silo-pair] phone sent done');
            _cancelAttempt();
            preserveTerminal = _settleEnd();
            if (!preserveTerminal) _restingStatus();
          case SiloPairingCancel(:final reason):
            appLogger.i('[silo-pair] phone cancelled reason=$reason');
            _cancelAttempt();
            if (_signedInNames.isNotEmpty) {
              _set(SiloPairingCompleted(List.of(_signedInNames)));
              preserveTerminal = true;
            } else {
              _restingStatus();
            }
          default:
            // TV→phone messages and unknown types are ignored.
            break;
        }
        if (message is SiloPairingDone || message is SiloPairingCancel) break;
      }
      if (!preserveTerminal) preserveTerminal = _settleEnd();
    } catch (e) {
      appLogger.i('[silo-pair] connection ended: ${e.runtimeType}');
      preserveTerminal = _settleEnd();
    } finally {
      if (identical(_transport, transport)) {
        _sessionClosing = true;
        _idleTimer?.cancel();
        _idleTimer = null;
        _cancelAttempt();
        _pendingPush = null;
        final decision = _alternateDecision;
        _alternateDecision = null;
        if (decision != null && !decision.isCompleted) decision.complete(_AlternateChoice.retry);
        _transport = null;
        _sessionBinding = null;
        if (!preserveTerminal) _restingStatus();
        appLogger.i('[silo-pair] session ended with ${_signedInNames.length} account(s)');
      }
      await transport.close();
      if (_transport == null && !_disposed) onSessionEnd?.call();
    }
  }

  /// The session's end: a sign-in shows Completed, a lone failure stays.
  bool _settleEnd() {
    if (_signedInNames.isNotEmpty) {
      _set(SiloPairingCompleted(List.of(_signedInNames)));
      return true;
    }
    return status.value is SiloPairingFailed;
  }

  void _armIdleTimer(SiloPairingTransport transport) {
    if (_sessionClosing || !identical(_transport, transport)) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      if (!identical(_transport, transport) || _attempt != null) return;
      appLogger.i('[silo-pair] phone silent for ${idleTimeout.inSeconds} s; closing');
      _pendingPush = null;
      unawaited(transport.close());
    });
  }

  void _cancelAttempt() {
    final attempt = _attempt;
    _attempt = null;
    attempt?.cancel();
  }

  void _onPush(SiloPairingPushServer push, SiloPairingTransport transport) {
    if (_sessionDenied) return;
    appLogger.i('[silo-pair] phone pushed a server (accounts so far ${_signedInNames.length})');
    // One server at a time: a newer push means the phone gave up on the last.
    _cancelAttempt();
    if (_signedInNames.isNotEmpty && advertisement.state == SiloPairingReceiverState.login) {
      // The sign-in screen signs in its one account.
      appLogger.i('[silo-pair] push refused: limit_reached (sign-in screen)');
      unawaited(_sendResult(transport, push.serverUrl, SiloPairingFailureCode.limitReached));
      return;
    }
    final origin = _httpOrigin(push.serverUrl);
    final unencrypted = origin != null && !_approvedHttpOrigins.contains(origin);
    if (!_consented || unencrypted) {
      _armIdleTimer(transport);
      _pendingPush = push;
      _set(
        SiloPairingConsentRequested(
          serverUrl: push.serverUrl,
          serverName: push.displayName,
          unencrypted: unencrypted,
          signIn: advertisement.state == SiloPairingReceiverState.login,
        ),
      );
      return;
    }
    _beginAttempt(push, transport);
  }

  void _beginAttempt(SiloPairingPushServer push, SiloPairingTransport transport) {
    if (_sessionClosing || !identical(_transport, transport)) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    final attempt = _attempt = _Attempt(push, advertisement);
    unawaited(() async {
      if (attempt.advertisement.state == SiloPairingReceiverState.login) {
        await _runLogin(attempt, transport);
      } else {
        await _runSetup(attempt, transport);
      }
      attempt.finished = true;
      if (identical(_attempt, attempt)) {
        _attempt = null;
        _armIdleTimer(transport);
      }
    }());
  }

  Future<void> _runLogin(_Attempt attempt, SiloPairingTransport transport) async {
    final push = attempt.push;
    final name = push.displayName;
    try {
      final pushed = push.serverIdentity?.trim();
      final expected = attempt.advertisement.serverIdentity;
      if (expected == null || pushed == null || pushed.isEmpty || pushed != expected) {
        throw const SiloPairingAttemptFailure(SiloPairingFailureCode.identityMismatch);
      }
      _set(SiloPairingWorking(name, accountName: push.accountLabel));
      final code = await attempt.guard(port.currentCode());
      if (code == null) throw const SiloPairingAttemptFailure(SiloPairingFailureCode.expired);
      await _sendStarted(attempt, transport, code);
      final failure = await attempt.guard(port.outcome(code.deviceCode));
      if (failure != null) throw SiloPairingAttemptFailure(failure);
      await _reportSignedIn(attempt, transport);
    } on SiloPairingAttemptFailure catch (f) {
      await _reportFailure(attempt, transport, f.code);
    } on _AttemptCancelled {
      // The sign-in screen keeps its own code; nothing to withdraw.
    } catch (e) {
      appLogger.w('[silo-pair] sign-in attempt failed', error: e);
      await _reportFailure(attempt, transport, SiloPairingFailureCode.authFailed);
    }
  }

  Future<void> _runSetup(_Attempt attempt, SiloPairingTransport transport) async {
    final push = attempt.push;
    var settled = false;
    try {
      _set(SiloPairingWorking(push.displayName, accountName: push.accountLabel));
      final target = await _resolveTarget(attempt);
      final code = await attempt.guard(port.startSetup(target, binding: _sessionBinding));
      attempt.deviceCode = code.deviceCode;
      await _sendStarted(attempt, transport, code);
      final failure = await attempt.guard(port.outcome(code.deviceCode));
      if (failure != null) throw SiloPairingAttemptFailure(failure);
      settled = true;
      await _reportSignedIn(attempt, transport);
    } on SiloPairingAttemptFailure catch (f) {
      await _reportFailure(attempt, transport, f.code);
    } on _AttemptCancelled {
      // Abandoned below.
    } catch (e) {
      appLogger.w('[silo-pair] setup attempt failed', error: e);
      await _reportFailure(attempt, transport, SiloPairingFailureCode.authFailed);
    } finally {
      // Anything but a sign-in leaves the code screen and withdraws its code.
      if (!settled) port.abandonSetup(attempt.deviceCode);
    }
  }

  Future<void> _sendStarted(_Attempt attempt, SiloPairingTransport transport, SiloPairingCode code) async {
    if (attempt.isCancelled) throw const _AttemptCancelled();
    _set(SiloPairingAwaitingApproval(serverName: attempt.push.displayName, userCode: code.userCode));
    await transport.send(
      SiloPairingDeviceStarted(serverUrl: attempt.push.serverUrl, userCode: code.userCode, matchCode: code.matchCode),
    );
    appLogger.i('[silo-pair] sent deviceStarted');
  }

  /// `setup`: the address to sign in at. With a pushed identity the pushed
  /// address must answer it from here; a different answer is refused. If it
  /// does not answer, the other offered addresses are checked and the first
  /// with the same identity is offered, never taken. A push without an
  /// identity (older phones) uses the pushed address as is.
  Future<SiloPairingTarget> _resolveTarget(_Attempt attempt) async {
    final push = attempt.push;
    final name = push.displayName;
    final pushedIdentity = push.serverIdentity?.trim();
    if (pushedIdentity == null || pushedIdentity.isEmpty) {
      return SiloPairingTarget(url: push.serverUrl, serverName: name);
    }
    final pushedUrl = normalizeSiloPairingUrl(push.serverUrl);
    final endpoints = push.endpoints ?? const <SiloPairingEndpoint>[];
    while (true) {
      final probe = await attempt.guard(identityProbe(pushedUrl));
      switch (probe) {
        case SiloIdentityAnswer(:final serverId):
          if (serverId == pushedIdentity) {
            appLogger.i('[silo-pair] identity matched at the pushed address');
            return SiloPairingTarget(url: push.serverUrl, serverName: name, verifiedServerId: pushedIdentity);
          }
          appLogger.i('[silo-pair] another server answered at the pushed address');
          throw const SiloPairingAttemptFailure(SiloPairingFailureCode.identityMismatch);
        case SiloIdentityUnsupported():
          throw const SiloPairingAttemptFailure(SiloPairingFailureCode.identityMismatch);
        case SiloIdentityUnreachable():
          break;
      }
      SiloPairingEndpoint? alternate;
      for (final endpoint in endpoints) {
        if (endpoint.url == pushedUrl) continue;
        final answer = await attempt.guard(identityProbe(endpoint.url));
        if (answer is SiloIdentityAnswer && answer.serverId == pushedIdentity) {
          alternate = endpoint;
          break;
        }
      }
      final provider = endpoints
          .where((e) => e.kind == SiloPairingEndpointKind.provider && e.url == pushedUrl)
          .firstOrNull;
      final decision = _alternateDecision = Completer<_AlternateChoice>();
      appLogger.i('[silo-pair] pushed address unreachable; alternate=${alternate != null}');
      _set(
        SiloPairingUnreachable(
          serverUrl: push.serverUrl,
          serverName: name,
          providerName: (provider?.displayName?.trim().isEmpty ?? true) ? null : provider!.displayName,
          alternateUrl: alternate?.url,
        ),
      );
      final _AlternateChoice choice;
      try {
        choice = await attempt.guard(decision.future);
      } finally {
        if (identical(_alternateDecision, decision)) _alternateDecision = null;
      }
      _set(SiloPairingWorking(name, accountName: push.accountLabel));
      if (choice == _AlternateChoice.useAlternate && alternate != null) {
        return SiloPairingTarget(url: alternate.url, serverName: name, verifiedServerId: pushedIdentity);
      }
    }
  }

  Future<void> _reportSignedIn(_Attempt attempt, SiloPairingTransport transport) async {
    if (!identical(_transport, transport)) return;
    _signedInNames.add(attempt.push.displayName);
    _set(SiloPairingSignedIn(attempt.push.displayName, count: _signedInNames.length));
    appLogger.i('[silo-pair] signed in (accounts this session ${_signedInNames.length}); sending serverResult');
    // Best effort: the session is ours now, a lost frame does not undo it.
    try {
      await transport.send(
        SiloPairingServerResult(serverUrl: attempt.push.serverUrl, status: SiloPairingServerStatus.signedIn),
      );
    } catch (_) {}
  }

  Future<void> _reportFailure(_Attempt attempt, SiloPairingTransport transport, SiloPairingFailureCode code) async {
    if (!identical(_transport, transport) || attempt.isCancelled) return;
    appLogger.i('[silo-pair] attempt failed: ${code.wire}');
    _set(
      SiloPairingFailed(
        serverName: attempt.push.displayName,
        code: code,
        signIn: attempt.advertisement.state == SiloPairingReceiverState.login,
      ),
    );
    await _sendResult(transport, attempt.push.serverUrl, code);
  }

  Future<void> _sendResult(SiloPairingTransport transport, String serverUrl, SiloPairingFailureCode code) async {
    try {
      await transport.send(
        SiloPairingServerResult(serverUrl: serverUrl, status: SiloPairingServerStatus.failed, error: code.wire),
      );
    } catch (_) {}
  }

  static String? _httpOrigin(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) return null;
    return 'http://${uri.host.toLowerCase()}:${uri.hasPort ? uri.port : 80}';
  }

  /// Stop: close any session and release the status notifier.
  Future<void> dispose() async {
    if (_disposed) return;
    _cancelAttempt();
    final transport = _transport;
    if (transport != null) await transport.close();
    _idleTimer?.cancel();
    _disposed = true;
    status.dispose();
  }
}
