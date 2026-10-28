import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import 'silo_auth_service.dart';

/// What the device-code panel shows. Mirrors the states of Silo's TV sign-in
/// (`DeviceSignInMachine` / `TvSignInStatus` in silo-android).
enum SiloDeviceSignInStatus {
  /// Asking the server for a code.
  gettingCode,

  /// A live code, nobody has opened it yet.
  waiting,

  /// An approver looked the code up (the server's `opened` signal).
  opened,

  /// The code expired while the screen was open and was replaced.
  newCode,

  /// Calls have failed (network, 5xx) for a while. Still retrying.
  unreachable,

  /// The server has answered 429 for over a minute. Still retrying.
  tooManyRequests,

  /// Approved: the tokens are in [SiloDeviceSignInState.approval].
  approved,

  /// The approver declined. Waits for "Show a new code".
  denied,

  /// Codes were renewed for about an hour without approval. Waits for
  /// "Show a new code".
  paused,

  /// The server has no device sign-in (404/501 on start).
  noDeviceSignIn,

  /// The server or this app must be updated first (410/426).
  updateRequired,

  /// The server answered in a way retrying won't fix.
  failed;

  /// Whether the flow is waiting for the person rather than working.
  bool get isSettled => switch (this) {
    approved || denied || paused || noDeviceSignIn || updateRequired || failed => true,
    _ => false,
  };
}

@immutable
class SiloDeviceSignInState {
  final SiloDeviceSignInStatus status;

  /// The code to show, while it is live on the server.
  final SiloDeviceCode? code;

  /// The approving poll answer, for [SiloDeviceSignInStatus.approved].
  final SiloDevicePollResult? approval;

  const SiloDeviceSignInState(this.status, {this.code, this.approval});

  @override
  String toString() => 'SiloDeviceSignInState(${status.name}, code: ${code != null})';
}

/// Timing for [SiloDeviceSignIn]; Silo's defaults, shortened in tests.
@immutable
class SiloDeviceSignInConfig {
  /// Stop renewing codes after this long without approval.
  final Duration pauseAfter;

  /// Show "can't reach" when getting a code has failed for this long.
  final Duration startUnreachableAfter;

  /// Show "can't reach" when polling has failed for this long.
  final Duration pollUnreachableAfter;

  /// Show "too many attempts" when 429s have persisted this long.
  final Duration rateLimitedAfter;

  /// Backoff ceiling for network errors, 5xx and 429.
  final Duration maxBackoff;

  /// Codes the server drops at their first poll, in a row, before giving up
  /// (a proxy mangling the poll must not spin start/poll forever).
  final int maxImmediateLosses;

  const SiloDeviceSignInConfig({
    this.pauseAfter = const Duration(hours: 1),
    this.startUnreachableAfter = const Duration(seconds: 10),
    this.pollUnreachableAfter = const Duration(seconds: 30),
    this.rateLimitedAfter = const Duration(minutes: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.maxImmediateLosses = 3,
  });
}

enum _ErrorKind { transient, rateLimited, notFound, updateRequired, rejected }

_ErrorKind _classify(Object error) {
  if (error is SiloSignInException) return _ErrorKind.rejected;
  if (error is MediaServerHttpException) {
    final status = error.statusCode;
    if (status == null || status >= 500) return _ErrorKind.transient;
    if (status == 429) return _ErrorKind.rateLimited;
    if (status == 404 || status == 501) return _ErrorKind.notFound;
    if (status == 410 || status == 426) return _ErrorKind.updateRequired;
    return _ErrorKind.rejected;
  }
  // Timeouts, sockets and other transport failures.
  return _ErrorKind.transient;
}

/// The device-code sign-in of the add-server screen: gets a code, polls it,
/// renews it in place when it expires while the screen is open, pauses after
/// about an hour of renewals, reports a declined code, and names the failure
/// when the server can't be reached or keeps answering 429 (while still
/// polling). A port of Silo's TV `DeviceSignInMachine`.
///
/// [start] begins (or restarts) a run; a new [start] or [abandon] supersedes
/// the run before it, whose answers are then dropped. A code still live on
/// the server when it is replaced or abandoned is withdrawn there
/// (`/auth/device/cancel`). An approved code is consumed, so it is never
/// cancelled; if an approval lands after [abandon], its session is logged out.
class SiloDeviceSignIn {
  SiloDeviceSignIn({required this.auth, required this.server, this.config = const SiloDeviceSignInConfig()});

  final SiloAuthService auth;
  final SiloServerInfo server;
  final SiloDeviceSignInConfig config;

  final ValueNotifier<SiloDeviceSignInState> state = ValueNotifier(
    const SiloDeviceSignInState(SiloDeviceSignInStatus.gettingCode),
  );

  int _run = 0;
  bool _disposed = false;
  SiloDeviceCode? _code;
  DateTime? _deadline;

  /// The local deadline the current code started with (before extensions).
  DateTime? _baseDeadline;
  Timer? _waitTimer;
  Completer<void>? _wait;

  /// The live code, if any (for tests and the screen).
  SiloDeviceCode? get code => _code;

  /// Start a new run from "Getting a sign-in code", withdrawing any live code.
  Future<void> start() async {
    if (_disposed) return;
    final mine = _supersede();
    _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.gettingCode));
    try {
      await _runLoop(mine);
    } catch (e, st) {
      // Anything unexpected ends the run instead of escaping into the UI.
      appLogger.w('Silo device sign-in failed', error: e, stackTrace: st);
      if (mine == _run) {
        _code = null;
        _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.failed));
      }
    }
  }

  /// Stop the current run and withdraw its code on the server.
  void abandon() => _supersede();

  void dispose() {
    if (_disposed) return;
    _supersede();
    _disposed = true;
    state.dispose();
  }

  Future<void> _runLoop(int mine) async {
    final budgetStart = clock.now();
    var renewed = false;
    var immediateLosses = 0;
    var polledCurrent = false;
    DateTime? failingSince;
    DateTime? rateLimitedSince;
    var backoff = Duration.zero;

    void noteFailure(_ErrorKind kind, {required bool starting}) {
      final now = clock.now();
      final live = _liveCode();
      if (kind == _ErrorKind.rateLimited) {
        final since = rateLimitedSince ??= now;
        if (now.difference(since) >= config.rateLimitedAfter) {
          _publish(SiloDeviceSignInState(SiloDeviceSignInStatus.tooManyRequests, code: live));
        }
      } else {
        final since = failingSince ??= now;
        final threshold = starting ? config.startUnreachableAfter : config.pollUnreachableAfter;
        if (now.difference(since) >= threshold) {
          _publish(SiloDeviceSignInState(SiloDeviceSignInStatus.unreachable, code: live));
        }
      }
    }

    void recovered() {
      failingSince = null;
      rateLimitedSince = null;
      backoff = Duration.zero;
    }

    Duration nextBackoff(Duration base) {
      final next = backoff == Duration.zero ? base : backoff * 2;
      return backoff = next > config.maxBackoff ? config.maxBackoff : next;
    }

    while (mine == _run) {
      var code = _code;
      if (code == null) {
        if (clock.now().difference(budgetStart) >= config.pauseAfter) {
          _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.paused));
          return;
        }
        final SiloDeviceCode started;
        try {
          started = await auth.startDeviceLogin(server);
        } catch (e) {
          if (mine != _run) return;
          final kind = _classify(e);
          appLogger.d('Silo device start failed (${kind.name})', error: e.runtimeType);
          switch (kind) {
            case _ErrorKind.notFound:
              _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.noDeviceSignIn));
              return;
            case _ErrorKind.updateRequired:
              _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.updateRequired));
              return;
            case _ErrorKind.rejected:
              _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.failed));
              return;
            case _ErrorKind.transient || _ErrorKind.rateLimited:
              noteFailure(kind, starting: true);
              if (!await _pause(nextBackoff(const Duration(seconds: 1)), mine)) return;
              continue;
          }
        }
        if (mine != _run) {
          // Nobody will show or poll this code: withdraw it.
          unawaited(auth.cancelDeviceLogin(server, started));
          return;
        }
        recovered();
        code = _code = started;
        _deadline = _baseDeadline = clock.now().add(started.lifetime);
        polledCurrent = false;
        _publish(_showing(started, opened: false, renewed: renewed));
        // Poll at once.
      }

      final SiloDevicePollResult result;
      try {
        result = await auth.pollDeviceLogin(server, code);
      } catch (e) {
        if (mine != _run) return;
        final kind = _classify(e);
        if (kind == _ErrorKind.updateRequired) {
          _code = null;
          _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.updateRequired));
          return;
        }
        appLogger.d('Silo device poll failed; backing off', error: e.runtimeType);
        noteFailure(kind, starting: false);
        // Past the local deadline without an answer: the server may still
        // hold the code, so withdraw it before asking for a new one.
        if (_expired()) {
          await _replace(code, stillLive: true);
          renewed = true;
          continue;
        }
        if (!await _pause(_clampToDeadline(nextBackoff(code.interval)), mine)) return;
        continue;
      }

      if (mine != _run) {
        // The approval arrived for a flow nobody is watching: don't leave a
        // live session behind.
        final tokens = result.tokens;
        if (result.status == SiloDevicePollStatus.approved && tokens != null) {
          unawaited(auth.logout(server, tokens));
        }
        return;
      }

      switch (result.status) {
        case SiloDevicePollStatus.pending:
          recovered();
          immediateLosses = 0;
          polledCurrent = true;
          // Approver lookups can extend the request; apply the extension the
          // server reports relative to its own clock, so clock skew cannot
          // expire the code early.
          final extended = _extendedDeadline(code, result.expiresAt);
          if (extended != null && extended.isAfter(_deadline!)) _deadline = extended;
          _publish(_showing(code, opened: result.opened, renewed: renewed));
          if (_expired()) {
            await _replace(code, stillLive: true);
            renewed = true;
            continue;
          }
          if (!await _pause(_clampToDeadline(result.pollAfter ?? code.interval), mine)) return;
        case SiloDevicePollStatus.approved:
          // Consumed on the server: never cancel it.
          _code = null;
          _publish(SiloDeviceSignInState(SiloDeviceSignInStatus.approved, approval: result));
          return;
        case SiloDevicePollStatus.denied:
          _code = null;
          _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.denied));
          return;
        case SiloDevicePollStatus.failed:
          _code = null;
          _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.failed));
          return;
        case SiloDevicePollStatus.gone:
          // Gone on the server (expired, consumed, canceled): replace it in place.
          if (!polledCurrent && ++immediateLosses > config.maxImmediateLosses) {
            _code = null;
            _publish(const SiloDeviceSignInState(SiloDeviceSignInStatus.failed));
            return;
          }
          await _replace(code, stillLive: false);
          renewed = true;
      }
    }
  }

  SiloDeviceSignInState _showing(SiloDeviceCode code, {required bool opened, required bool renewed}) {
    final status = opened
        ? SiloDeviceSignInStatus.opened
        : (renewed ? SiloDeviceSignInStatus.newCode : SiloDeviceSignInStatus.waiting);
    return SiloDeviceSignInState(status, code: code);
  }

  /// A later server `expires_at` translated to this device's clock: the
  /// extension past the code's original server expiry, applied to its
  /// original local deadline. Null when either server time is missing.
  DateTime? _extendedDeadline(SiloDeviceCode code, DateTime? serverTime) {
    final base = code.serverExpiresAt;
    final localBase = _baseDeadline;
    if (serverTime == null || base == null || localBase == null) return null;
    return localBase.add(serverTime.difference(base));
  }

  bool _expired() {
    final deadline = _deadline;
    return deadline != null && !clock.now().isBefore(deadline);
  }

  Duration _clampToDeadline(Duration wait) {
    final deadline = _deadline;
    if (deadline == null) return wait;
    final left = deadline.difference(clock.now());
    if (left <= Duration.zero) return Duration.zero;
    return left < wait ? left : wait;
  }

  SiloDeviceCode? _liveCode() => _expired() ? null : _code;

  Future<void> _replace(SiloDeviceCode current, {required bool stillLive}) async {
    if (identical(_code, current)) {
      _code = null;
      _deadline = null;
    }
    if (stillLive) await auth.cancelDeviceLogin(server, current);
  }

  /// Retire the current run and withdraw its live code. Returns the new run.
  int _supersede() {
    final run = ++_run;
    _waitTimer?.cancel();
    _waitTimer = null;
    final wait = _wait;
    _wait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
    final code = _code;
    _code = null;
    _deadline = null;
    if (code != null) unawaited(auth.cancelDeviceLogin(server, code));
    return run;
  }

  /// Wait [duration]; false when the run [mine] was superseded meanwhile.
  Future<bool> _pause(Duration duration, int mine) async {
    if (mine != _run) return false;
    if (duration > Duration.zero) {
      final wait = _wait = Completer<void>();
      _waitTimer = Timer(duration, () {
        if (!wait.isCompleted) wait.complete();
      });
      await wait.future;
      if (identical(_wait, wait)) {
        _wait = null;
        _waitTimer = null;
      }
    }
    return mine == _run;
  }

  void _publish(SiloDeviceSignInState value) {
    if (_disposed) return;
    state.value = value;
  }
}
