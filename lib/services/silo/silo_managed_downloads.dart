import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../media/download_resolution.dart';
import '../../utils/app_logger.dart';
import '../base_shared_preferences_service.dart';
import 'silo_download_registry.dart';

/// Where [SiloManagedDownloads] keeps its records.
abstract interface class SiloManagedDownloadPersistence {
  Future<String?> read();
  Future<void> write(String value);
}

/// For tests, and the default until start-up configures the app's store.
class MemorySiloManagedDownloadPersistence implements SiloManagedDownloadPersistence {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

/// The app's preferences (no secrets: entry ids, revisions, presets).
class PrefsSiloManagedDownloadPersistence implements SiloManagedDownloadPersistence {
  static const key = 'silo_managed_downloads_v1';

  @override
  Future<String?> read() async => (await BaseSharedPreferencesService.sharedCache()).getString(key);

  @override
  Future<void> write(String value) async => (await BaseSharedPreferencesService.sharedCache()).setString(key, value);
}

/// The registry entry behind one local download (one download row).
class SiloManagedDownloadRecord {
  SiloManagedDownloadRecord({
    required this.globalKey,
    required this.scope,
    required this.entryId,
    required this.revision,
    required this.mediaFileId,
    required this.quality,
    this.deliveryFormat = 'original',
    this.pendingStatus,
    this.pendingAt,
    this.localComplete = false,
  });

  final String globalKey;

  /// The Silo connection id (`server/user/profile`): whose registry it is.
  final String scope;
  final String entryId;
  final int revision;
  final String mediaFileId;
  final String quality;
  final String deliveryFormat;

  /// A status event (`downloading` / `completed`) not yet acknowledged, and
  /// when the local state changed (kept for the retry, as the server asks).
  String? pendingStatus;
  DateTime? pendingAt;

  /// Every file is stored locally. A later resolution of the same file
  /// (subtitle enrichment, artwork repair) registers nothing again.
  bool localComplete;

  Map<String, dynamic> toJson() => {
    'scope': scope,
    'id': entryId,
    'revision': revision,
    'file': mediaFileId,
    'quality': quality,
    'format': deliveryFormat,
    'pending': ?pendingStatus,
    'pendingAt': ?pendingAt?.toUtc().toIso8601String(),
    if (localComplete) 'done': true,
  };

  static SiloManagedDownloadRecord? fromJson(String globalKey, Object? raw) {
    if (raw is! Map) return null;
    final scope = raw['scope'];
    final id = raw['id'];
    final file = raw['file'];
    if (scope is! String || id is! String || file is! String) return null;
    return SiloManagedDownloadRecord(
      globalKey: globalKey,
      scope: scope,
      entryId: id,
      revision: (raw['revision'] as num?)?.toInt() ?? 0,
      mediaFileId: file,
      quality: raw['quality']?.toString() ?? SiloDownloadQuality.originalPreset,
      deliveryFormat: raw['format']?.toString() ?? 'original',
      pendingStatus: raw['pending']?.toString(),
      pendingAt: DateTime.tryParse(raw['pendingAt']?.toString() ?? ''),
      localComplete: raw['done'] == true,
    );
  }
}

/// Where the download's bytes come from once its entry is ready.
class SiloManagedDownloadTarget {
  const SiloManagedDownloadTarget({required this.entryId, required this.useDirectLink});

  final String entryId;

  /// True for an entry served as the original file: the header-free
  /// direct-download link fetches it, so no credential rides with the task.
  /// False: the authenticated `/downloads/{id}/file` route (a prepared copy).
  final bool useDirectLink;

  String get filePath => SiloDownloadRegistryApi.filePath(entryId);
}

class _Attachment {
  _Attachment(this.api, this.isOffline);
  final SiloDownloadRegistryApi api;
  final bool Function() isOffline;
}

/// Keeps Plezilo's Silo downloads registered in Silo's managed downloads
/// registry (Silo Android #673 and the server's `docs/downloads-api.md`):
///
/// * a download is registered (`POST /downloads`, reconciled against the
///   registry first) before its bytes are fetched, and reports `downloading`
///   and then `completed` (`PATCH`, revision-bound, retried until the server
///   acknowledges);
/// * deleting the local copy deletes the entry (queued while offline);
/// * an entry an administrator revoked (`revoked_removes_local`) removes the
///   local copy through [onRevoked] and is then deleted;
/// * a quality preset other than original downloads the server's prepared
///   copy once it is ready.
///
/// Servers without the registry (no capability route, or one without
/// `bounded_creation` / `ordered_status`) keep the untracked direct
/// downloads: [prepare] returns null for them.
///
/// One instance for the app ([instance]); each [SiloClient] attaches its
/// registry calls under its connection id.
class SiloManagedDownloads implements DownloadServerTracker {
  SiloManagedDownloads({SiloManagedDownloadPersistence? persistence})
    : _persistence = persistence ?? MemorySiloManagedDownloadPersistence();

  static final instance = SiloManagedDownloads();

  SiloManagedDownloadPersistence _persistence;

  /// Removes the local copy of a revoked download (every profile's), and
  /// tells the user. Set at start-up; without it revoked entries are left
  /// for a later sync.
  Future<void> Function(String globalKey)? onRevoked;

  static const capabilityTtl = Duration(minutes: 5);
  static const tombstoneLifetime = Duration(days: 30);
  static const maxQualityChoices = 300;

  Timer? _periodic;
  final _attached = <String, _Attachment>{};
  final _syncedScopes = <String>{};
  final _capabilities = <String, ({SiloDownloadCapability? value, DateTime at})>{};
  final _capabilityReads = <String, Future<SiloDownloadCapability?>>{};
  final _syncs = <String, Future<void>>{};

  bool _loaded = false;
  Future<void>? _loading;
  final _records = <String, SiloManagedDownloadRecord>{};
  final _tombstones = <({String scope, String id, DateTime since})>[];
  final _quality = <String, String>{};
  Future<void> _writeChain = Future.value();

  /// Wire the app: its persistent store, the revocation handler, and a sync
  /// every [syncInterval] (plus one shortly after each client attaches).
  void configure({
    required SiloManagedDownloadPersistence persistence,
    required Future<void> Function(String globalKey) onRevoked,
    Duration syncInterval = const Duration(minutes: 30),
  }) {
    _persistence = persistence;
    _loaded = false;
    _loading = null;
    this.onRevoked = onRevoked;
    _periodic?.cancel();
    _periodic = Timer.periodic(syncInterval, (_) => syncAll());
    DownloadServerTrackers.register(this);
  }

  @visibleForTesting
  void resetForTesting({SiloManagedDownloadPersistence? persistence}) {
    _periodic?.cancel();
    _periodic = null;
    onRevoked = null;
    _persistence = persistence ?? MemorySiloManagedDownloadPersistence();
    _attached.clear();
    _syncedScopes.clear();
    _capabilities.clear();
    _capabilityReads.clear();
    _syncs.clear();
    _records.clear();
    _tombstones.clear();
    _quality.clear();
    _loaded = false;
    _loading = null;
    DownloadServerTrackers.unregister(this);
  }

  // ---------------------------------------------------------------------------
  // Clients
  // ---------------------------------------------------------------------------

  /// A live client of connection [scope]. The latest attachment wins.
  void attach(String scope, SiloDownloadRegistryApi api, {bool Function()? isOffline}) {
    _attached[scope] = _Attachment(api, isOffline ?? () => false);
    if (_periodic != null && _syncedScopes.add(scope)) {
      Timer(const Duration(seconds: 10), () => unawaited(sync(scope)));
    }
  }

  void detach(String scope, SiloDownloadRegistryApi api) {
    if (identical(_attached[scope]?.api, api)) _attached.remove(scope);
  }

  /// The capability of [scope], cached for [capabilityTtl]; null when the
  /// server has no registry. A transport failure throws (and is not cached).
  Future<SiloDownloadCapability?> capability(String scope, SiloDownloadRegistryApi api, {bool refresh = false}) {
    final cached = _capabilities[scope];
    if (!refresh && cached != null && clock.now().difference(cached.at) < capabilityTtl) {
      return Future.value(cached.value);
    }
    final running = _capabilityReads[scope];
    if (running != null) return running;
    final read = () async {
      SiloDownloadCapability? value;
      try {
        value = await api.capability();
      } on MediaServerHttpException catch (e) {
        if (e.isTransient || e.isCancellation || (e.statusCode ?? 0) >= 500 || e.statusCode == 401) rethrow;
        appLogger.d('Silo: download capability refused (${e.statusCode}); untracked downloads');
        value = null;
      }
      _capabilities[scope] = (value: value, at: clock.now());
      return value;
    }();
    _capabilityReads[scope] = read;
    return read.whenComplete(() => _capabilityReads.remove(scope));
  }

  // ---------------------------------------------------------------------------
  // Quality choice
  // ---------------------------------------------------------------------------

  static String _qualityKey(String scope, String itemId) => '$scope|$itemId';

  /// Remember [preset] for [itemId] (a movie, episode, season or show) and
  /// the downloads queued under it.
  Future<void> setQuality(String scope, String itemId, String preset) async {
    await _ensureLoaded();
    final key = _qualityKey(scope, itemId);
    // Original is stored too: it overrides a season's or show's preset.
    _quality.remove(key);
    _quality[key] = preset;
    while (_quality.length > maxQualityChoices) {
      _quality.remove(_quality.keys.first);
    }
    await _save();
  }

  /// The preset chosen for the first of [itemIds] that has one (the item,
  /// then its season, then its show), or null (original).
  Future<String?> qualityFor(String scope, Iterable<String?> itemIds) async {
    await _ensureLoaded();
    for (final id in itemIds) {
      if (id == null || id.isEmpty) continue;
      final preset = _quality[_qualityKey(scope, id)];
      if (preset != null) return preset;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Registering a download
  // ---------------------------------------------------------------------------

  /// Register the download of file [mediaFileId] for [globalKey] and say
  /// where its bytes come from, or return null on a server without the
  /// registry (the caller keeps the untracked direct download).
  ///
  /// Throws [DownloadNotReadyException] while the server prepares a
  /// converted copy, and a [MediaServerHttpException] (with the row's
  /// sentence) when the server refuses or revoked the download.
  Future<SiloManagedDownloadTarget?> prepare({
    required String scope,
    required SiloDownloadRegistryApi api,
    required String globalKey,
    required String contentId,
    String? episodeId,
    required String mediaFileId,
    List<String?> qualityItemIds = const [],
  }) async {
    final cap = await capability(scope, api);
    if (cap == null || !cap.managesDownloads) return null;
    await _ensureLoaded();
    final stored = _records[globalKey];
    if (stored != null && stored.localComplete && stored.scope == scope && stored.mediaFileId == mediaFileId) {
      // The copy is complete (this is subtitle or artwork follow-up work):
      // point at the same bytes without registering or reporting again.
      return SiloManagedDownloadTarget(
        entryId: stored.entryId,
        useDirectLink: stored.deliveryFormat == 'original' && cap.directDownloadLinks,
      );
    }
    final quality = cap.effectivePreset(await qualityFor(scope, qualityItemIds));
    await _flush(scope, api);

    final entries = await api.list();
    final record = _records[globalKey];
    final matches = entries
        .where(
          (e) =>
              e.mediaFileId == mediaFileId ||
              (episodeId != null && e.episodeId == episodeId) ||
              e.episodeId == contentId ||
              (e.contentId == contentId && e.episodeId == null && episodeId == null),
        )
        .toList();
    var existing =
        matches.where((e) => e.id == record?.entryId).firstOrNull ??
        matches.where((e) => e.mediaFileId == mediaFileId).firstOrNull ??
        matches.firstOrNull;

    if (existing != null && existing.isRevoked) {
      if (record != null && record.entryId == existing.id && record.scope == scope) {
        // This very download was revoked: its copy goes, and nothing is fetched.
        if (cap.revokedRemovesLocal) _scheduleRevocation(globalKey);
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          statusCode: 409,
          message: 'Silo: download revoked',
          display: t.siloManagedDownloads.errorRevoked,
        );
      }
      // A revoked entry this device holds nothing for: confirm it, then
      // register the new download from scratch.
      await api.delete(existing.id);
      existing = null;
    }

    SiloDownloadEntry entry;
    if (existing != null &&
        existing.mediaFileId == mediaFileId &&
        existing.quality == quality &&
        existing.isUsable &&
        !existing.isRevoked) {
      entry = existing;
      // A finished prepared copy fetched again: the server may have cleaned
      // its file up since (`prepare_again`). Asking is idempotent.
      if (entry.status == 'completed' && !entry.servesOriginal && cap.prepareAgain) {
        entry = await api.prepareAgain(entry.id) ?? entry;
      }
    } else {
      entry = await api.create(
        contentId: contentId,
        episodeId: episodeId,
        mediaFileId: mediaFileId,
        quality: quality,
        expected: existing,
      );
    }

    if (record != null && record.entryId != entry.id && record.scope == scope) {
      // The row now follows another entry; the old one is no longer this copy's.
      _tombstones.add((scope: scope, id: record.entryId, since: clock.now()));
    }
    final next = SiloManagedDownloadRecord(
      globalKey: globalKey,
      scope: scope,
      entryId: entry.id,
      revision: entry.revision,
      mediaFileId: entry.mediaFileId,
      quality: entry.quality,
      deliveryFormat: entry.deliveryFormat,
    );
    _records[globalKey] = next;
    await _save();

    if (entry.isPreparing) {
      throw DownloadNotReadyException(_preparingMessage(entry), retryAfter: _preparingRetry(entry));
    }
    if (entry.isFailed) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: 409,
        message: 'Silo: download preparation failed',
        display: t.siloManagedDownloads.errorPreparationFailed,
      );
    }
    if (!entry.isUsable) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: 409,
        message: 'Silo: download entry not servable (${entry.status})',
        display: t.siloManagedDownloads.errorChanged,
      );
    }

    final useDirectLink = entry.servesOriginal && cap.directDownloadLinks;
    if (!useDirectLink && !cap.fileDelivery) {
      throw UnsupportedError('This Silo server does not offer download files; update the server.');
    }

    next
      ..pendingStatus = 'downloading'
      ..pendingAt = clock.now();
    await _save();
    await _flush(scope, api);
    return SiloManagedDownloadTarget(entryId: entry.id, useDirectLink: useDirectLink);
  }

  static String _preparingMessage(SiloDownloadEntry entry) {
    final progress = entry.preparationProgress;
    if (progress != null && progress > 0) {
      return t.siloManagedDownloads.preparingProgress(percent: (progress * 100).clamp(0, 100).round());
    }
    final position = entry.queuePosition;
    if (position != null && position > 0) return t.siloManagedDownloads.preparingQueued(position: position);
    return t.siloManagedDownloads.preparing;
  }

  /// Ask again when the encode should be done, but at least every 15 s and
  /// at most every 2 minutes (the server refreshes progress every 5 s).
  static Duration _preparingRetry(SiloDownloadEntry entry) {
    final remaining = entry.remainingSeconds;
    if (remaining == null) return const Duration(seconds: 30);
    return Duration(seconds: remaining.clamp(15, 120));
  }

  void _scheduleRevocation(String globalKey) {
    final handler = onRevoked;
    if (handler == null) return;
    // Not awaited: the download being prepared is the one this removes.
    Timer.run(
      () => unawaited(
        handler(globalKey).catchError((Object e) {
          appLogger.w('Silo: removing a revoked download failed', error: e);
        }),
      ),
    );
  }

  /// The record behind [globalKey], if any.
  Future<SiloManagedDownloadRecord?> recordFor(String globalKey) async {
    await _ensureLoaded();
    return _records[globalKey];
  }

  @visibleForTesting
  Future<List<String>> tombstonesForTesting() async {
    await _ensureLoaded();
    return [for (final t in _tombstones) t.id];
  }

  // ---------------------------------------------------------------------------
  // Local life of the copy (DownloadServerTracker)
  // ---------------------------------------------------------------------------

  @override
  Future<void> localCopyCompleted(String globalKey) async {
    await _ensureLoaded();
    final record = _records[globalKey];
    if (record == null) return;
    record
      ..pendingStatus = 'completed'
      ..pendingAt = clock.now()
      ..localComplete = true;
    await _save();
    final attached = _attached[record.scope];
    if (attached != null && !attached.isOffline()) await _flush(record.scope, attached.api);
  }

  @override
  Future<void> localCopyRemoved(String globalKey) async {
    await _ensureLoaded();
    final record = _records.remove(globalKey);
    if (record == null) return;
    _tombstones.add((scope: record.scope, id: record.entryId, since: clock.now()));
    await _save();
    final attached = _attached[record.scope];
    if (attached != null && !attached.isOffline()) await _flush(record.scope, attached.api);
  }

  // ---------------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------------

  /// [sync] every attached connection.
  Future<void> syncAll() async {
    for (final scope in _attached.keys.toList()) {
      await sync(scope);
    }
  }

  /// Send what is pending for [scope], then read the registry: remove the
  /// local copies an administrator revoked and forget records the server
  /// no longer has. Best effort; one at a time per connection.
  Future<void> sync(String scope) {
    final running = _syncs[scope];
    if (running != null) return running;
    final attached = _attached[scope];
    if (attached == null || attached.isOffline()) return Future.value();
    final run = _sync(scope, attached.api).catchError((Object e) {
      appLogger.d('Silo: download registry sync failed', error: e.runtimeType);
    });
    _syncs[scope] = run;
    return run.whenComplete(() => _syncs.remove(scope));
  }

  Future<void> _sync(String scope, SiloDownloadRegistryApi api) async {
    await _ensureLoaded();
    final cap = await capability(scope, api, refresh: true);
    if (cap == null || !cap.managesDownloads) return;
    await _flush(scope, api);
    final entries = await api.list();
    final byId = {for (final e in entries) e.id: e};

    for (final entry in entries.where((e) => e.isRevoked)) {
      if (!cap.revokedRemovesLocal) continue;
      final record = _records.values.where((r) => r.scope == scope && r.entryId == entry.id).firstOrNull;
      if (record == null) {
        // Nothing of it here: confirming the removal is all that is left.
        await api.delete(entry.id);
        continue;
      }
      final handler = onRevoked;
      if (handler == null) continue;
      appLogger.i('Silo: a download was revoked on the server; removing the local copy');
      // The removal reaches [localCopyRemoved], which deletes the entry.
      await handler(record.globalKey);
      if (_records[record.globalKey]?.entryId == entry.id) {
        // The handler kept the copy (it failed); try again at the next sync.
        continue;
      }
    }

    // Finished copies whose entries the server no longer lists (deleted
    // there): the local file stays playable, it just stops being reported.
    // An unfinished one is registered again by its next resolution.
    final gone = _records.values
        .where((r) => r.scope == scope && r.localComplete && r.pendingStatus == null && !byId.containsKey(r.entryId))
        .toList();
    if (gone.isNotEmpty) {
      for (final record in gone) {
        _records.remove(record.globalKey);
      }
      await _save();
    }
  }

  /// Send [scope]'s pending status events and deletions. Failures stay
  /// queued for the next try.
  Future<void> _flush(String scope, SiloDownloadRegistryApi api) async {
    var changed = false;
    for (final record in _records.values.where((r) => r.scope == scope && r.pendingStatus != null).toList()) {
      final status = record.pendingStatus!;
      final at = record.pendingAt ?? clock.now();
      try {
        await api.reportStatus(record.entryId, status: status, updatedAt: at, revision: record.revision);
        if (record.pendingStatus == status && record.pendingAt == at) {
          record
            ..pendingStatus = null
            ..pendingAt = null;
          changed = true;
        }
      } catch (e) {
        appLogger.d('Silo: download status report deferred', error: e.runtimeType);
      }
    }
    final now = clock.now();
    for (final tombstone in _tombstones.where((t) => t.scope == scope).toList()) {
      try {
        await api.delete(tombstone.id);
        _tombstones.remove(tombstone);
        changed = true;
      } catch (e) {
        appLogger.d('Silo: download entry deletion deferred', error: e.runtimeType);
      }
    }
    final before = _tombstones.length;
    _tombstones.removeWhere((t) => now.difference(t.since) > tombstoneLifetime);
    if (changed || before != _tombstones.length) await _save();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _persistence.read();
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw);
        if (json is Map) {
          final records = json['records'];
          if (records is Map) {
            for (final entry in records.entries) {
              final record = SiloManagedDownloadRecord.fromJson(entry.key.toString(), entry.value);
              if (record != null) _records[record.globalKey] = record;
            }
          }
          final tombstones = json['tombstones'];
          if (tombstones is List) {
            for (final raw in tombstones.whereType<Map>()) {
              final scope = raw['scope'];
              final id = raw['id'];
              final since = DateTime.tryParse(raw['since']?.toString() ?? '');
              if (scope is String && id is String) _tombstones.add((scope: scope, id: id, since: since ?? clock.now()));
            }
          }
          final quality = json['quality'];
          if (quality is Map) {
            for (final entry in quality.entries) {
              if (entry.value is String) _quality[entry.key.toString()] = entry.value as String;
            }
          }
        }
      }
    } catch (e) {
      appLogger.w('Silo: managed download records unreadable; starting empty', error: e.runtimeType);
    }
    _loaded = true;
  }

  Future<void> _save() {
    final snapshot = jsonEncode({
      'records': {for (final r in _records.values) r.globalKey: r.toJson()},
      'tombstones': [
        for (final t in _tombstones) {'scope': t.scope, 'id': t.id, 'since': t.since.toUtc().toIso8601String()},
      ],
      'quality': _quality,
    });
    return _writeChain = _writeChain.then((_) => _persistence.write(snapshot)).catchError((Object e) {
      appLogger.w('Silo: managed download records not saved', error: e.runtimeType);
    });
  }
}
