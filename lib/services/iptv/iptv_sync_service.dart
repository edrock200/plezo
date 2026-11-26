import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

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
  IptvSyncService({this.storeOverride, this.useIsolate = true});

  static IptvSyncService? _instance;
  static IptvSyncService get instance => _instance ??= IptvSyncService();
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

  ValueNotifier<IptvSourceSyncStatus> statusOf(String sourceId) =>
      _status.putIfAbsent(sourceId, () => ValueNotifier(const IptvSourceSyncStatus()));

  /// Start watching [connection]: refresh what is stale.
  void watch(IptvConnection connection) {
    _sources[connection.id] = connection;
    _timer ??= Timer.periodic(const Duration(minutes: 15), (_) => unawaited(checkAll()));
    unawaited(_loadStatus(connection.id));
    unawaited(check(connection.id));
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
    if (c == null) return;
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
        final worker = IptvSyncWorker(store: store, onProgress: onProgress);
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
    await _loadStatus(c.id);
    notifier.value = notifier.value.copyWith(
      running: false,
      progress: IptvSyncProgress(error == null ? IptvSyncPhase.done : IptvSyncPhase.failed, message: error),
    );
    appLogger.i('[iptv] refresh ${error == null ? 'finished' : 'failed: $error'}');
    IptvDataRevision.bump(c.id);
    onSourceUpdated?.call(c.id);
  }

  /// Forget a removed source's status.
  void forget(String sourceId) {
    unwatch(sourceId);
    _status.remove(sourceId)?.dispose();
  }
}
