import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../connection/connection.dart';
import '../../utils/app_logger.dart';
import 'iptv_client.dart';
import 'iptv_store.dart';
import 'iptv_sync_worker.dart';

/// The refresh state of one source, for its settings page.
class IptvSourceSyncStatus {
  const IptvSourceSyncStatus({
    this.running = false,
    this.progress,
    this.playlist = const IptvSyncRecord(),
    this.epg = const IptvSyncRecord(),
  });

  final bool running;
  final IptvSyncProgress? progress;
  final IptvSyncRecord playlist;
  final IptvSyncRecord epg;

  IptvSourceSyncStatus copyWith({
    bool? running,
    IptvSyncProgress? progress,
    IptvSyncRecord? playlist,
    IptvSyncRecord? epg,
  }) => IptvSourceSyncStatus(
    running: running ?? this.running,
    progress: progress ?? this.progress,
    playlist: playlist ?? this.playlist,
    epg: epg ?? this.epg,
  );
}

/// One refresh job sent to the background isolate.
class _SyncJob {
  const _SyncJob(this.connection, this.databasePath, this.playlist, this.epg, this.progress);
  final IptvConnection connection;
  final String databasePath;
  final bool playlist;
  final bool epg;
  final SendPort progress;
}

/// Runs in the background isolate: its own connection to the IPTV database,
/// its own HTTP client. Returns an error message, or null.
Future<String?> _runSyncJob(_SyncJob job) async {
  final db = IptvDatabase.openSync(job.databasePath);
  final store = IptvStore(db);
  final worker = IptvSyncWorker(
    store: store,
    onProgress: (p) => job.progress.send([p.phase.index, p.count, p.message]),
  );
  try {
    if (job.playlist) await worker.importPlaylist(job.connection);
    if (job.epg) await worker.importEpg(job.connection);
    return null;
  } on IptvSyncException catch (e) {
    return e.message;
  } catch (e) {
    return 'refresh failed (${e.runtimeType})';
  } finally {
    worker.close();
    await db.close();
  }
}

/// Kept apart so the isolate's closure holds nothing but [job].
Future<String?> _spawn(_SyncJob job) => Isolate.run(() => _runSyncJob(job));

/// Keeps every IPTV source's playlist and guide fresh.
///
/// A refresh runs in a background isolate (parsing and database writes never
/// touch the UI isolate), one source at a time. Sources are checked when they
/// are connected and every 15 minutes after; a source is refreshed when its
/// playlist or guide is older than its interval, or never loaded.
class IptvSyncService {
  IptvSyncService({
    this.storeOverride,
    this.useIsolate = true,
    this.httpClientFactory,
    this.startDelay = Duration.zero,
    this.startDeadline = Duration.zero,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (startDelay > Duration.zero) {
      Timer(startDelay, () {
        _delayPassed = true;
        _maybeStart();
      });
    } else {
      _delayPassed = true;
    }
    if (startDeadline > Duration.zero && !_homeSeen) {
      _deadlineTimer = Timer(startDeadline, () {
        _homeLoaded = true;
        _maybeStart();
      });
    } else {
      _homeLoaded = true;
    }
    _maybeStart();
  }

  /// The app's service: automatic refreshes wait about a minute after launch
  /// and for Home's first load (or at most three minutes), so a large source
  /// never competes with the app starting up. Asked refreshes run at once.
  static IptvSyncService _production() =>
      IptvSyncService(startDelay: const Duration(seconds: 60), startDeadline: const Duration(minutes: 3));

  final DateTime Function() _now;

  /// How long after creation automatic refreshes may start.
  final Duration startDelay;

  /// Automatic refreshes also wait for [homeLoaded], at most this long.
  final Duration startDeadline;

  Timer? _deadlineTimer;
  bool _delayPassed = false;
  bool _homeLoaded = false;
  bool _started = false;

  static bool _homeSeen = false;

  /// Home finished its first load (called by Home; never creates the
  /// service): automatic refreshes may start once the start delay passed.
  static void markHomeLoaded() {
    _homeSeen = true;
    _instance?.homeLoaded();
  }

  /// Home finished its first load: automatic refreshes may start (once the
  /// start delay has passed).
  void homeLoaded() {
    if (_homeLoaded) return;
    _homeLoaded = true;
    _maybeStart();
  }

  bool get automaticStarted => _started;

  void _maybeStart() {
    if (_started || !_delayPassed || !_homeLoaded) return;
    _started = true;
    _deadlineTimer?.cancel();
    appLogger.i('[iptv] automatic refreshes start (${_sources.length} source(s))');
    unawaited(checkAll());
  }

  // ---- crash-loop guard ----------------------------------------------------

  /// Meta keys: when the running refresh started (cleared when it ends), how
  /// many refreshes in a row the app died in, and until when automatic
  /// refreshes wait after that.
  static const runningSinceKey = 'refresh_running_since';
  static const interruptedKey = 'refresh_interrupted';
  static const holdUntilKey = 'refresh_hold_until';

  /// The sync error a source shows after a refresh the app died in.
  static const interruptedError = 'interrupted';

  /// Each source's marker is looked at once per run (shared by concurrent
  /// checks).
  final Map<String, Future<void>> _markerChecks = {};

  /// Sources whose automatic refresh is skipped for the rest of this run.
  final Set<String> _skipThisRun = {};

  Future<void> _checkMarker(IptvConnection c) async {
    final since = await store.meta(c.id, runningSinceKey);
    if (since == null) return;
    final count = (int.tryParse(await store.meta(c.id, interruptedKey) ?? '') ?? 0) + 1;
    await store.putMeta(c.id, interruptedKey, '$count');
    await store.putMeta(c.id, runningSinceKey, null);
    await store.recordSync(c.id, IptvSyncWorker.playlistKind, ok: false, error: interruptedError);
    _skipThisRun.add(c.id);
    if (count >= 2) {
      final until = _now().add(Duration(hours: c.playlistRefreshHours.clamp(1, 24 * 14)));
      await store.putMeta(c.id, holdUntilKey, '${until.millisecondsSinceEpoch}');
      appLogger.w(
        '[iptv] last refresh did not finish ($count in a row); automatic refresh waits for the next interval',
      );
    } else {
      appLogger.w('[iptv] last refresh did not finish; automatic refresh skipped this run');
    }
    await _loadStatus(c.id);
  }

  /// Looks for a refresh the app died in (its marker is still there); true
  /// when the automatic refresh must wait.
  Future<bool> _guarded(IptvConnection c) async {
    await (_markerChecks[c.id] ??= _checkMarker(c));
    if (_skipThisRun.contains(c.id)) return true;
    final hold = int.tryParse(await store.meta(c.id, holdUntilKey) ?? '');
    if (hold != null && _now().millisecondsSinceEpoch < hold) return true;
    return false;
  }

  /// The HTTP client of an in-process refresh (tests).
  final http.Client Function()? httpClientFactory;

  static IptvSyncService? _instance;
  static IptvSyncService get instance => _instance ??= _production();
  static set testInstance(IptvSyncService? service) => _instance = service;

  /// The store to use instead of the app's (tests).
  final IptvStore? storeOverride;
  IptvStore get store => storeOverride ?? IptvStore.instance;

  /// False in tests: refresh on this isolate.
  final bool useIsolate;

  /// Path of the database file for the worker isolate.
  String? databasePath;

  final Map<String, IptvConnection> _sources = {};
  final Map<String, ValueNotifier<IptvSourceSyncStatus>> _status = {};
  final Map<String, Future<void>> _running = {};
  Future<void> _queue = Future<void>.value();
  Timer? _timer;

  /// Called after a source's data changed (refresh done): the app re-reads
  /// Live TV availability and libraries.
  void Function(String sourceId)? onSourceUpdated;

  /// Called after every refresh of a source, whether or not the UI is up
  /// (series recording rules are expanded against the new guide).
  void Function(String sourceId)? onGuideRefreshed;

  ValueNotifier<IptvSourceSyncStatus> statusOf(String sourceId) =>
      _status.putIfAbsent(sourceId, () => ValueNotifier(const IptvSourceSyncStatus()));

  /// Start watching [connection]: refresh what is stale.
  void watch(IptvConnection connection) {
    _sources[connection.id] = connection;
    _timer ??= Timer.periodic(const Duration(minutes: 15), (_) {
      if (_started) unawaited(checkAll());
    });
    unawaited(_loadStatus(connection.id));
    _maybeStart();
    if (_started) unawaited(check(connection.id));
  }

  /// Adopt edited settings of a watched source without refreshing it.
  void update(IptvConnection connection) {
    if (_sources.containsKey(connection.id)) _sources[connection.id] = connection;
  }

  /// Stop watching (the source was switched off or removed).
  void unwatch(String sourceId) {
    _sources.remove(sourceId);
    if (_sources.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _loadStatus(String sourceId) async {
    try {
      final playlist = await store.syncRecord(sourceId, IptvSyncWorker.playlistKind);
      final epg = await store.syncRecord(sourceId, IptvSyncWorker.epgKind);
      final notifier = statusOf(sourceId);
      notifier.value = notifier.value.copyWith(playlist: playlist, epg: epg);
    } catch (e) {
      appLogger.d('[iptv] sync state unreadable (${e.runtimeType})');
    }
  }

  Future<void> checkAll() async {
    for (final id in _sources.keys.toList()) {
      await check(id);
    }
  }

  /// Refresh [sourceId]'s playlist and/or guide when stale.
  Future<void> check(String sourceId) async {
    final c = _sources[sourceId];
    if (c == null || _running.containsKey(sourceId)) return;
    if (await _guarded(c)) return;
    final playlist = await store.syncRecord(sourceId, IptvSyncWorker.playlistKind);
    final epg = await store.syncRecord(sourceId, IptvSyncWorker.epgKind);
    final now = DateTime.now();
    bool stale(IptvSyncRecord r, int hours) {
      final last = r.lastSuccess;
      if (last == null) {
        // Don't hammer a failing source: retry a failure after 30 minutes.
        final attempt = r.lastAttempt;
        return attempt == null || now.difference(attempt) > const Duration(minutes: 30);
      }
      return now.difference(last) > Duration(hours: hours.clamp(1, 24 * 14));
    }

    final needPlaylist = stale(playlist, c.playlistRefreshHours);
    final needEpg = needPlaylist || stale(epg, c.epgRefreshHours);
    if (!needPlaylist && !needEpg) return;
    await refresh(sourceId, playlist: needPlaylist, epg: needEpg);
  }

  /// Refresh now (the user asked, or [check] found it stale). Shares a running
  /// refresh of the same source.
  Future<void> refresh(String sourceId, {bool playlist = true, bool epg = true, IptvConnection? connection}) {
    final c = connection ?? _sources[sourceId];
    if (c == null) return Future<void>.value();
    final running = _running[sourceId];
    if (running != null) return running;
    final job = _queue.then((_) => _run(c, playlist: playlist, epg: epg));
    _queue = job.catchError((_) {});
    _running[sourceId] = job;
    return job.whenComplete(() => _running.remove(sourceId));
  }

  bool isRunning(String sourceId) => _running.containsKey(sourceId);

  Future<void> _run(IptvConnection c, {required bool playlist, required bool epg}) async {
    final notifier = statusOf(c.id);
    notifier.value = notifier.value.copyWith(
      running: true,
      progress: IptvSyncProgress(playlist ? IptvSyncPhase.playlist : IptvSyncPhase.guide),
    );
    appLogger.i('[iptv] refresh started playlist=$playlist guide=$epg');
    // Left behind only if the app dies during the refresh ([_guarded]).
    await (_markerChecks[c.id] ??= _checkMarker(c));
    try {
      await store.putMeta(c.id, runningSinceKey, '${_now().millisecondsSinceEpoch}');
    } catch (_) {}
    String? error;
    void onProgress(IptvSyncProgress p) {
      notifier.value = notifier.value.copyWith(progress: p);
    }

    try {
      final path = databasePath;
      if (useIsolate && path != null) {
        final port = ReceivePort();
        final sub = port.listen((message) {
          if (message is List && message.length == 3) {
            onProgress(
              IptvSyncProgress(
                IptvSyncPhase.values[message[0] as int],
                count: message[1] as int,
                message: message[2] as String?,
              ),
            );
          }
        });
        try {
          error = await _spawn(_SyncJob(c, path, playlist, epg, port.sendPort));
        } finally {
          await sub.cancel();
          port.close();
        }
      } else {
        final worker = IptvSyncWorker(store: store, onProgress: onProgress, client: httpClientFactory?.call());
        try {
          if (playlist) await worker.importPlaylist(c);
          if (epg) await worker.importEpg(c);
        } on IptvSyncException catch (e) {
          error = e.message;
        } finally {
          worker.close();
        }
      }
    } catch (e) {
      error = 'refresh failed (${e.runtimeType})';
    }
    try {
      await store.putMeta(c.id, runningSinceKey, null);
      if (error == null) {
        await store.putMeta(c.id, interruptedKey, null);
        await store.putMeta(c.id, holdUntilKey, null);
        _skipThisRun.remove(c.id);
      }
    } catch (_) {}
    await _loadStatus(c.id);
    notifier.value = notifier.value.copyWith(
      running: false,
      progress: IptvSyncProgress(error == null ? IptvSyncPhase.done : IptvSyncPhase.failed, message: error),
    );
    appLogger.i('[iptv] refresh ${error == null ? 'finished' : 'failed: $error'}');
    IptvDataRevision.bump(c.id);
    onGuideRefreshed?.call(c.id);
    onSourceUpdated?.call(c.id);
  }

  /// Forget a removed source's status.
  void forget(String sourceId) {
    unwatch(sourceId);
    _markerChecks.remove(sourceId);
    _skipThisRun.remove(sourceId);
    _status.remove(sourceId)?.dispose();
  }
}
