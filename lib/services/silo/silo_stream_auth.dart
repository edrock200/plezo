import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../utils/app_logger.dart';
import 'silo_api.dart';

/// Keeps a playing stream's account authentication valid.
///
/// Silo checks the `Authorization` header on every stream, manifest and
/// segment request, and access tokens live minutes to an hour, so a film
/// outlives the token it started with (Silo's Android apps refresh through
/// `MediaAuthInterceptor`). While at least one stream holds it, this refreshes
/// the token once half of its life is spent and hands each holder the new
/// stream headers, which the player then sends from its next request on.
class SiloStreamAuth {
  SiloStreamAuth({required this._api, required this._headers});

  final SiloApi _api;
  final Map<String, String> Function() _headers;

  final Map<Object, void Function(Map<String, String> headers)> _holders = {};
  Timer? _timer;
  bool _closed = false;
  bool _refreshing = false;

  /// Wait before the next check after a refresh that did not rotate the token
  /// (no network, a 5xx); the next 401 also refreshes on its own.
  static const retryDelay = Duration(seconds: 60);

  /// Never check sooner than this, whatever the token says.
  static const minDelay = Duration(seconds: 15);

  @visibleForTesting
  bool get isScheduled => _timer != null;

  /// Keep the token fresh while a stream plays. [onHeaders] receives the
  /// stream headers after every token change. Call the returned function when
  /// the stream stops; the timer runs while any holder is left.
  void Function() hold(void Function(Map<String, String> headers) onHeaders) {
    final key = Object();
    if (_closed) return () {};
    _holders[key] = onHeaders;
    if (_timer == null) _schedule();
    return () {
      _holders.remove(key);
      if (_holders.isEmpty) _cancel();
    };
  }

  /// The client's token pair changed (a refresh, or a pair adopted from a
  /// client it replaced): every holder gets the new headers.
  void tokensChanged() {
    if (_closed || _holders.isEmpty) return;
    final headers = _headers();
    for (final onHeaders in List.of(_holders.values)) {
      try {
        onHeaders(headers);
      } catch (e, st) {
        appLogger.w('Silo: updating stream headers failed', error: e, stackTrace: st);
      }
    }
    _schedule();
  }

  /// The server refused a stream request with 401: refresh now (shared with
  /// any refresh already running). Holders hear of a new token through
  /// [tokensChanged]. True when the token changed.
  Future<bool> refreshAfterRefusal() async {
    if (_closed) return false;
    final before = _api.accessToken;
    await _api.refreshTokens();
    return _api.accessToken != before;
  }

  /// When to check next for [tokens]: just after half of their life is spent,
  /// never before [minDelay]. Null when the expiry is unknown (nothing to
  /// plan; a 401 still refreshes).
  @visibleForTesting
  static Duration? delayFor(SiloTokens? tokens, DateTime now) {
    final expiresAt = tokens?.expiresAt;
    if (tokens == null || expiresAt == null) return null;
    final lifetime = tokens.lifetimeSeconds ?? 3600;
    final halfSpentAt = expiresAt.subtract(Duration(seconds: lifetime ~/ 2));
    final delay = halfSpentAt.difference(now) + const Duration(seconds: 1);
    return delay < minDelay ? minDelay : delay;
  }

  void _schedule({Duration? after}) {
    _timer?.cancel();
    _timer = null;
    if (_closed || _holders.isEmpty) return;
    final delay = after ?? delayFor(_api.tokens, DateTime.now());
    if (delay == null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (_closed || _holders.isEmpty || _refreshing) return;
    _refreshing = true;
    final before = _api.accessToken;
    try {
      await _api.refreshTokensIfHalfSpent();
    } catch (e) {
      appLogger.d('Silo: stream token refresh failed', error: e.runtimeType);
    } finally {
      _refreshing = false;
    }
    if (_closed || _holders.isEmpty) return;
    // A rotation already rescheduled through tokensChanged; an unchanged
    // token that is still half spent means the refresh failed.
    if (_api.accessToken != before) return;
    final next = delayFor(_api.tokens, DateTime.now());
    _schedule(after: next == null || next <= minDelay ? retryDelay : next);
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// The client is closing: stop the timer for good.
  void close() {
    _closed = true;
    _holders.clear();
    _cancel();
  }
}
