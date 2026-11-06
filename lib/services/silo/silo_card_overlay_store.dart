import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import 'silo_card_overlays.dart';

/// One read of a Silo settings route: the JSON body, or null when the server
/// does not have the route (404). Any other failure throws.
typedef SiloOverlayRead = Future<Map<String, dynamic>?> Function();

/// The card overlays one Silo client (one account acting as one Silo
/// profile) draws, as Silo's `OverlayPrefsStore` reads them: the overlay
/// config and the profile's two values, read together under one shared
/// in-flight future, settled into [SiloCardOverlaySettings].
///
/// [value] is null until the first answer (cards then show Plezy's own
/// watch indicators). A failed read keeps what applies; a 404 counts as
/// "nothing there" (a server without the route draws the built-in document).
/// The last settled value per connection is remembered for the process, so a
/// client rebuilt for the same profile draws at once.
class SiloCardOverlayStore extends ValueNotifier<SiloCardOverlaySettings?> {
  SiloCardOverlayStore({
    required this.cacheKey,
    required this._readConfig,
    required this._readValues,
    bool Function()? isOffline,
    this.minRefreshInterval = const Duration(seconds: 30),
  }) : _isOffline = isOffline ?? _never,
       super(_known[cacheKey]);

  static bool _never() => false;

  /// Settled values by [cacheKey] (the Silo connection id), for clients
  /// rebuilt in this process. Bounded (least recently written first out) and
  /// pruned when a connection is removed ([forget]).
  static final _known = <String, SiloCardOverlaySettings>{};

  /// The most connections [_known] remembers.
  @visibleForTesting
  static const maxKnown = 32;

  static void _remember(String key, SiloCardOverlaySettings settings) {
    _known.remove(key);
    _known[key] = settings;
    while (_known.length > maxKnown) {
      _known.remove(_known.keys.first);
    }
  }

  /// Forget the remembered settings of a removed connection.
  static void forget(String cacheKey) => _known.remove(cacheKey);

  @visibleForTesting
  static int get knownCountForTesting => _known.length;

  @visibleForTesting
  static void resetKnownForTesting() => _known.clear();

  final String cacheKey;
  final SiloOverlayRead _readConfig;
  final SiloOverlayRead _readValues;
  final bool Function() _isOffline;

  /// A refresh sooner than this after the last read is skipped (Home reads
  /// often), unless forced.
  final Duration minRefreshInterval;

  Future<void>? _inFlight;
  DateTime? _lastRead;
  String? _signature;
  bool _disposed = false;

  /// Uploaded images that did not load this session; their badges draw
  /// without them.
  final _failedImages = <String>{};

  /// Read the settings if this store has not read them yet. Never notifies
  /// synchronously, so a card may call it while building.
  Future<void> ensureLoaded() => _lastRead == null ? refresh() : (_inFlight ?? Future.value());

  /// Read the settings again (on profile Home loads), sharing a read in
  /// flight; skipped within [minRefreshInterval] of the last unless [force].
  Future<void> refresh({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final last = _lastRead;
    if (!force && last != null && clock.now().difference(last) < minRefreshInterval) return Future.value();
    if (_isOffline()) return Future.value();
    _lastRead = clock.now();
    return _inFlight = _read().whenComplete(() => _inFlight = null);
  }

  Future<void> _read() async {
    Map<String, dynamic>? config;
    Map<String, dynamic>? values;
    var failed = false;
    await Future.wait([
      _readConfig().then(
        (body) => config = body,
        onError: (Object e) {
          failed = true;
          appLogger.d('Silo: overlay config unavailable; keeping card overlays as they are', error: e.runtimeType);
        },
      ),
      _readValues().then(
        (body) => values = body,
        onError: (Object e) {
          failed = true;
          appLogger.d('Silo: overlay settings unavailable; keeping card overlays as they are', error: e.runtimeType);
        },
      ),
    ]);
    if (failed || _disposed) return;
    final signature = _signatureOf(config, values);
    if (signature == _signature && value != null) return;
    var settled = SiloCardOverlaySettings.settle(
      values == null ? null : SiloOverlayProfileValues.fromEffective(values),
      config,
    );
    for (final ref in _failedImages) {
      settled = settled.withoutImage(ref);
    }
    _signature = signature;
    _remember(cacheKey, settled);
    value = settled;
  }

  static String _signatureOf(Map<String, dynamic>? config, Map<String, dynamic>? values) {
    try {
      return jsonEncode([config, values]);
    } catch (_) {
      return '${config.hashCode}/${values.hashCode}';
    }
  }

  /// An uploaded image ([ref]) failed to load: draw its badges without it.
  void imageFailed(String ref) {
    if (_disposed || !_failedImages.add(ref)) return;
    // Image errors can arrive while a frame builds; never notify mid-build.
    scheduleMicrotask(() {
      final current = value;
      if (_disposed || current == null) return;
      final next = current.withoutImage(ref);
      if (identical(next, current)) return;
      _remember(cacheKey, next);
      value = next;
    });
  }

  /// Whether the client that owned this store closed it. Cards holding it
  /// look up their item's live client again.
  bool get isDisposed => _disposed;

  /// Disposed with its client. Listeners hear one last notification first,
  /// so a card still showing this store switches to its replacement's.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    notifyListeners();
    super.dispose();
  }
}
