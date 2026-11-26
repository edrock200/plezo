import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';
import 'iptv_catchup.dart';

/// Kinds of group (category) an IPTV source has.
enum IptvGroupKind {
  live,
  movie,
  series;

  String get id => name;
  static IptvGroupKind parse(String raw) => values.firstWhere((v) => v.name == raw, orElse: () => live);
}

/// One channel as imported, with the user's overrides applied by
/// [IptvStore.channels].
class IptvChannel {
  const IptvChannel({
    required this.sourceId,
    required this.id,
    required this.name,
    required this.sortIndex,
    this.originalName,
    this.number,
    this.playlistNumber,
    this.group,
    this.logo,
    this.url = '',
    this.tvgId,
    this.tvgName,
    this.tvgShiftHours,
    this.catchupMode = IptvCatchupMode.none,
    this.catchupDays,
    this.catchupSource,
    this.radio = false,
    this.headers = const {},
    this.xtreamId,
    this.epgChannelId,
    this.manualEpgId,
    this.hidden = false,
    this.shiftMinutes = 0,
  });

  final String sourceId;
  final String id;

  /// The name shown: the user's rename, else the playlist's.
  final String name;
  final String? originalName;

  /// The number shown (override, playlist or automatic; filled by the client).
  final String? number;

  /// `tvg-chno` / Xtream `num`.
  final String? playlistNumber;
  final int sortIndex;
  final String? group;
  final String? logo;

  /// Stream URL; empty for Xtream channels, whose URL is built from the login.
  final String url;
  final String? tvgId;
  final String? tvgName;
  final double? tvgShiftHours;
  final IptvCatchupMode catchupMode;
  final int? catchupDays;
  final String? catchupSource;
  final bool radio;
  final Map<String, String> headers;
  final String? xtreamId;

  /// The guide channel this channel reads (the user's choice, else the match).
  final String? epgChannelId;
  final String? manualEpgId;
  final bool hidden;

  /// The user's extra guide shift for this channel.
  final int shiftMinutes;

  bool get hasCatchup => catchupMode != IptvCatchupMode.none && (catchupDays ?? 0) > 0;

  IptvChannel copyWith({String? number}) => IptvChannel(
    sourceId: sourceId,
    id: id,
    name: name,
    originalName: originalName,
    number: number ?? this.number,
    playlistNumber: playlistNumber,
    sortIndex: sortIndex,
    group: group,
    logo: logo,
    url: url,
    tvgId: tvgId,
    tvgName: tvgName,
    tvgShiftHours: tvgShiftHours,
    catchupMode: catchupMode,
    catchupDays: catchupDays,
    catchupSource: catchupSource,
    radio: radio,
    headers: headers,
    xtreamId: xtreamId,
    epgChannelId: epgChannelId,
    manualEpgId: manualEpgId,
    hidden: hidden,
    shiftMinutes: shiftMinutes,
  );
}

/// A guide entry (epoch seconds, already shifted when read through
/// [IptvStore.programmes]).
class IptvProgramme {
  const IptvProgramme({
    required this.epgChannelId,
    required this.start,
    required this.stop,
    required this.title,
    this.subTitle,
    this.description,
    this.category,
    this.icon,
    this.episode,
    this.season,
    this.episodeNumber,
    this.rating,
    this.year,
    this.isNew = false,
  });

  final String epgChannelId;
  final int start;
  final int stop;
  final String title;
  final String? subTitle;
  final String? description;
  final String? category;
  final String? icon;
  final String? episode;
  final int? season;
  final int? episodeNumber;
  final String? rating;
  final int? year;

  /// The guide marks it a new episode (XMLTV `<new/>`).
  final bool isNew;

  IptvProgramme shifted(int seconds) => seconds == 0
      ? this
      : IptvProgramme(
          epgChannelId: epgChannelId,
          start: start + seconds,
          stop: stop + seconds,
          title: title,
          subTitle: subTitle,
          description: description,
          category: category,
          icon: icon,
          episode: episode,
          season: season,
          episodeNumber: episodeNumber,
          rating: rating,
          year: year,
          isNew: isNew,
        );
}

/// An Xtream movie or series row.
class IptvVodRow {
  const IptvVodRow({
    required this.sourceId,
    required this.kind,
    required this.id,
    required this.name,
    required this.sortIndex,
    this.categoryId,
    this.poster,
    this.rating,
    this.year,
    this.added,
    this.extension,
    this.plot,
    this.genre,
    this.url,
    this.headers = const {},
  });

  final String sourceId;
  final IptvGroupKind kind;
  final String id;
  final String name;
  final int sortIndex;
  final String? categoryId;
  final String? poster;
  final double? rating;
  final int? year;

  /// Epoch seconds.
  final int? added;
  final String? extension;
  final String? plot;
  final String? genre;

  /// M3U movies only: the playlist entry's address and its own headers.
  /// Xtream rows never store an address (it carries the login).
  final String? url;
  final Map<String, String> headers;
}

class IptvGroup {
  const IptvGroup({
    required this.kind,
    required this.id,
    required this.name,
    required this.sortIndex,
    this.hidden = false,
    this.count = 0,
  });
  final IptvGroupKind kind;
  final String id;
  final String name;
  final int sortIndex;
  final bool hidden;
  final int count;
}

/// Locally kept playback state of a VOD item (Xtream has none server-side).
class IptvProgress {
  const IptvProgress({
    required this.itemId,
    required this.positionMs,
    required this.durationMs,
    required this.watched,
    required this.updatedAt,
    this.meta = const {},
  });
  final String itemId;
  final int positionMs;
  final int durationMs;
  final bool watched;

  /// Epoch milliseconds.
  final int updatedAt;

  /// The item as it was played (title, artwork, parent), for Continue
  /// Watching without a server round trip.
  final Map<String, Object?> meta;
}

class IptvReminder {
  const IptvReminder({
    required this.sourceId,
    required this.channelId,
    required this.start,
    required this.stop,
    required this.title,
    this.channelName,
  });
  final String sourceId;
  final String channelId;
  final int start;
  final int stop;
  final String title;
  final String? channelName;
}

enum IptvRecordingState { scheduled, recording, completed, failed, cancelled }

/// "Record series": every airing of a title on its channel (or any
/// channel), new episodes only if asked, keeping the latest [keepLast]
/// (0 = all).
class IptvRecordingRule {
  const IptvRecordingRule({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.channelId,
    required this.createdAt,
    this.channelName,
    this.anyChannel = false,
    this.newOnly = false,
    this.keepLast = 0,
  });
  final String id;
  final String sourceId;
  final String title;

  /// The channel the rule was made on.
  final String channelId;
  final String? channelName;
  final bool anyChannel;
  final bool newOnly;
  final int keepLast;

  /// Epoch seconds.
  final int createdAt;

  IptvRecordingRule copyWith({bool? newOnly, int? keepLast, bool? anyChannel}) => IptvRecordingRule(
    id: id,
    sourceId: sourceId,
    title: title,
    channelId: channelId,
    channelName: channelName,
    createdAt: createdAt,
    anyChannel: anyChannel ?? this.anyChannel,
    newOnly: newOnly ?? this.newOnly,
    keepLast: keepLast ?? this.keepLast,
  );
}

class IptvRecordingRow {
  const IptvRecordingRow({
    required this.id,
    required this.sourceId,
    required this.channelId,
    required this.title,
    required this.start,
    required this.stop,
    required this.state,
    this.channelName,
    this.path,
    this.bytes = 0,
    this.error,
    this.ruleId,
    this.episode,
  });
  final String id;
  final String sourceId;
  final String channelId;
  final String? channelName;

  /// The series rule that scheduled it, or null.
  final String? ruleId;

  /// The guide's episode number, for a rule's duplicate check.
  final String? episode;
  final String title;
  final int start;
  final int stop;
  final IptvRecordingState state;
  final String? path;
  final int bytes;
  final String? error;
}

/// The outcome of the last playlist or guide refresh of a source.
class IptvSyncRecord {
  const IptvSyncRecord({this.lastSuccess, this.lastAttempt, this.error, this.count = 0});
  final DateTime? lastSuccess;
  final DateTime? lastAttempt;
  final String? error;
  final int count;
}

const _schema = <String>[
  '''CREATE TABLE IF NOT EXISTS channels (
    source_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, number TEXT, sort_index INTEGER NOT NULL,
    grp TEXT, logo TEXT, url TEXT NOT NULL, tvg_id TEXT, tvg_name TEXT, tvg_shift REAL,
    catchup TEXT, catchup_days INTEGER, catchup_source TEXT, radio INTEGER NOT NULL DEFAULT 0,
    headers TEXT, xtream_id TEXT, epg_id TEXT, name_lower TEXT NOT NULL,
    PRIMARY KEY (source_id, id))''',
  'CREATE INDEX IF NOT EXISTS channels_sort ON channels (source_id, sort_index)',
  // A playlist import writes here in batches; the commit swaps it in.
  '''CREATE TABLE IF NOT EXISTS channels_staging (
    source_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, number TEXT, sort_index INTEGER NOT NULL,
    grp TEXT, logo TEXT, url TEXT NOT NULL, tvg_id TEXT, tvg_name TEXT, tvg_shift REAL,
    catchup TEXT, catchup_days INTEGER, catchup_source TEXT, radio INTEGER NOT NULL DEFAULT 0,
    headers TEXT, xtream_id TEXT, epg_id TEXT, name_lower TEXT NOT NULL,
    PRIMARY KEY (source_id, id))''',
  'CREATE INDEX IF NOT EXISTS channels_epg ON channels (source_id, epg_id)',
  'CREATE INDEX IF NOT EXISTS channels_grp ON channels (source_id, grp)',
  '''CREATE TABLE IF NOT EXISTS groups (
    source_id TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, sort_index INTEGER NOT NULL,
    PRIMARY KEY (source_id, kind, id))''',
  '''CREATE TABLE IF NOT EXISTS programmes (
    source_id TEXT NOT NULL, channel TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL,
    title TEXT NOT NULL, sub_title TEXT, descr TEXT, category TEXT, icon TEXT, episode TEXT,
    season INTEGER, ep INTEGER, rating TEXT, year INTEGER, title_lower TEXT NOT NULL,
    is_new INTEGER NOT NULL DEFAULT 0)''',
  'CREATE INDEX IF NOT EXISTS programmes_channel_time ON programmes (source_id, channel, start)',
  'CREATE INDEX IF NOT EXISTS programmes_time ON programmes (source_id, stop, start)',
  '''CREATE TABLE IF NOT EXISTS programmes_staging (
    source_id TEXT NOT NULL, channel TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL,
    title TEXT NOT NULL, sub_title TEXT, descr TEXT, category TEXT, icon TEXT, episode TEXT,
    season INTEGER, ep INTEGER, rating TEXT, year INTEGER, title_lower TEXT NOT NULL,
    is_new INTEGER NOT NULL DEFAULT 0)''',
  'CREATE INDEX IF NOT EXISTS programmes_staging_source ON programmes_staging (source_id)',
  '''CREATE TABLE IF NOT EXISTS epg_channels (
    source_id TEXT NOT NULL, id TEXT NOT NULL, display_name TEXT NOT NULL, name_norm TEXT NOT NULL, icon TEXT,
    PRIMARY KEY (source_id, id, name_norm))''',
  'CREATE INDEX IF NOT EXISTS epg_channels_norm ON epg_channels (source_id, name_norm)',
  '''CREATE TABLE IF NOT EXISTS epg_channels_staging (
    source_id TEXT NOT NULL, id TEXT NOT NULL, display_name TEXT NOT NULL, name_norm TEXT NOT NULL, icon TEXT,
    PRIMARY KEY (source_id, id, name_norm))''',
  '''CREATE TABLE IF NOT EXISTS vod (
    source_id TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, name_lower TEXT NOT NULL,
    category_id TEXT, poster TEXT, rating REAL, year INTEGER, added INTEGER, ext TEXT, plot TEXT, genre TEXT,
    sort_index INTEGER NOT NULL, url TEXT, headers TEXT, PRIMARY KEY (source_id, kind, id))''',
  'CREATE INDEX IF NOT EXISTS vod_category ON vod (source_id, kind, category_id, sort_index)',
  '''CREATE TABLE IF NOT EXISTS vod_staging (
    source_id TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, name_lower TEXT NOT NULL,
    category_id TEXT, poster TEXT, rating REAL, year INTEGER, added INTEGER, ext TEXT, plot TEXT, genre TEXT,
    sort_index INTEGER NOT NULL, url TEXT, headers TEXT, PRIMARY KEY (source_id, kind, id))''',
  'CREATE INDEX IF NOT EXISTS vod_added ON vod (source_id, kind, added)',
  '''CREATE TABLE IF NOT EXISTS channel_overrides (
    source_id TEXT NOT NULL, channel_id TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0, name TEXT, number TEXT,
    epg_id TEXT, shift_minutes INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (source_id, channel_id))''',
  '''CREATE TABLE IF NOT EXISTS group_overrides (
    source_id TEXT NOT NULL, kind TEXT NOT NULL, group_id TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0,
    sort_index INTEGER, PRIMARY KEY (source_id, kind, group_id))''',
  '''CREATE TABLE IF NOT EXISTS favorites (
    source_id TEXT NOT NULL, channel_id TEXT NOT NULL, sort_index INTEGER NOT NULL,
    PRIMARY KEY (source_id, channel_id))''',
  '''CREATE TABLE IF NOT EXISTS recents (
    source_id TEXT NOT NULL, channel_id TEXT NOT NULL, watched_at INTEGER NOT NULL,
    PRIMARY KEY (source_id, channel_id))''',
  '''CREATE TABLE IF NOT EXISTS progress (
    source_id TEXT NOT NULL, item_id TEXT NOT NULL, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
    watched INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL, meta TEXT,
    PRIMARY KEY (source_id, item_id))''',
  'CREATE INDEX IF NOT EXISTS progress_updated ON progress (source_id, updated_at)',
  '''CREATE TABLE IF NOT EXISTS reminders (
    source_id TEXT NOT NULL, channel_id TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL,
    title TEXT NOT NULL, channel_name TEXT, PRIMARY KEY (source_id, channel_id, start))''',
  '''CREATE TABLE IF NOT EXISTS recordings (
    id TEXT NOT NULL PRIMARY KEY, source_id TEXT NOT NULL, channel_id TEXT NOT NULL, channel_name TEXT,
    title TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, state TEXT NOT NULL, path TEXT,
    bytes INTEGER NOT NULL DEFAULT 0, error TEXT, rule_id TEXT, episode TEXT)''',
  'CREATE INDEX IF NOT EXISTS recordings_rule ON recordings (rule_id)',
  '''CREATE TABLE IF NOT EXISTS recording_rules (
    id TEXT NOT NULL PRIMARY KEY, source_id TEXT NOT NULL, title TEXT NOT NULL, title_lower TEXT NOT NULL,
    channel_id TEXT NOT NULL, channel_name TEXT, any_channel INTEGER NOT NULL DEFAULT 0,
    new_only INTEGER NOT NULL DEFAULT 0, keep_last INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)''',
  '''CREATE TABLE IF NOT EXISTS sync_state (
    source_id TEXT NOT NULL, kind TEXT NOT NULL, last_success INTEGER, last_attempt INTEGER, error TEXT,
    count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (source_id, kind))''',
  '''CREATE TABLE IF NOT EXISTS source_meta (
    source_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY (source_id, key))''',
];

/// The IPTV database: a drift database of its own (`iptv.sqlite`), apart from
/// the app database, so guides of hundreds of thousands of rows never weigh
/// on the app database's migrations, backups and tvOS recovery, and a source's
/// data can be dropped or rebuilt freely. Tables are plain SQL (no codegen).
class IptvDatabase extends GeneratedDatabase {
  IptvDatabase(super.executor);

  /// The production file, opened with its own background isolate so queries
  /// never run on the UI isolate.
  static Future<IptvDatabase> open({File? file}) async {
    final target = file ?? await defaultFile();
    await target.parent.create(recursive: true);
    return IptvDatabase(NativeDatabase.createInBackground(target, setup: configure));
  }

  /// A connection for another isolate (the refresh worker) on the same file.
  static IptvDatabase openSync(String path) => IptvDatabase(NativeDatabase(File(path), setup: configure));

  static Future<File> defaultFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'iptv.sqlite'));
  }

  static void configure(dynamic db) {
    // `db` is sqlite3's Database; typed dynamically to avoid a direct import
    // of the transitive sqlite3 package.
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA busy_timeout=10000');
    db.execute('PRAGMA synchronous=NORMAL');
  }

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final statement in _schema) {
        await customStatement(statement);
      }
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // Series recording rules: new-episode flags and rule links.
        for (final statement in const [
          'ALTER TABLE programmes ADD COLUMN is_new INTEGER NOT NULL DEFAULT 0',
          'ALTER TABLE programmes_staging ADD COLUMN is_new INTEGER NOT NULL DEFAULT 0',
          'ALTER TABLE recordings ADD COLUMN rule_id TEXT',
          'ALTER TABLE recordings ADD COLUMN episode TEXT',
          // M3U movies keep their playlist address (never an Xtream one).
          'ALTER TABLE vod ADD COLUMN url TEXT',
          'ALTER TABLE vod ADD COLUMN headers TEXT',
        ]) {
          try {
            await customStatement(statement);
          } catch (e) {
            if (!'$e'.contains('duplicate column')) rethrow;
          }
        }
      }
      // From 3: staging tables for playlist and movie imports (created below).
      for (final statement in _schema) {
        await customStatement(statement);
      }
    },
  );
}

/// Reads and writes of the IPTV database. Every method is scoped to a source
/// id (the connection id) so sources never see each other's rows.
class IptvStore {
  IptvStore(this.db);

  final IptvDatabase db;

  static IptvStore? _instance;

  /// The app's store, opened by [initialize] at start-up.
  static IptvStore get instance {
    final store = _instance;
    if (store == null) throw StateError('IptvStore.initialize was not called');
    return store;
  }

  static bool get isInitialized => _instance != null;

  static Future<IptvStore> initialize({IptvDatabase? database}) async {
    final existing = _instance;
    if (existing != null && database == null) return existing;
    final store = IptvStore(database ?? await IptvDatabase.open());
    _instance = store;
    return store;
  }

  /// Test seam: replace (or clear) the shared store.
  static set testInstance(IptvStore? store) => _instance = store;

  static const _batchSize = 2000;

  Future<void> _insertMany(String sql, List<List<Object?>> rows) async {
    for (var i = 0; i < rows.length; i += _batchSize) {
      final end = i + _batchSize > rows.length ? rows.length : i + _batchSize;
      await db.batch((b) {
        for (var j = i; j < end; j++) {
          b.customStatement(sql, rows[j]);
        }
      });
    }
  }

  // ---- channels ----------------------------------------------------------

  static const _channelColumns =
      'source_id, id, name, number, sort_index, grp, logo, url, tvg_id, tvg_name, '
      'tvg_shift, catchup, catchup_days, catchup_source, radio, headers, xtream_id, epg_id, name_lower';

  /// Replace a source's channels and live groups with a fresh import (small
  /// lists; imports stage in batches: [beginChannelImport]).
  Future<void> replaceChannels(String sourceId, List<IptvChannel> channels, List<IptvGroup> groups) async {
    await beginChannelImport(sourceId);
    await stageChannels(sourceId, channels);
    await commitChannelImport(sourceId, groups);
  }

  /// Start a playlist import: clears this source's staged channels.
  Future<void> beginChannelImport(String sourceId) =>
      db.customStatement('DELETE FROM channels_staging WHERE source_id = ?', [sourceId]);

  Future<void> stageChannels(String sourceId, List<IptvChannel> channels) => _insertMany(
    'INSERT OR REPLACE INTO channels_staging ($_channelColumns) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      for (final c in channels)
        [
          sourceId,
          c.id,
          c.originalName ?? c.name,
          c.playlistNumber,
          c.sortIndex,
          c.group,
          c.logo,
          c.url,
          c.tvgId,
          c.tvgName,
          c.tvgShiftHours,
          c.catchupMode.id,
          c.catchupDays,
          c.catchupSource,
          c.radio ? 1 : 0,
          c.headers.isEmpty ? null : jsonEncode(c.headers),
          c.xtreamId,
          c.epgChannelId,
          (c.originalName ?? c.name).toLowerCase(),
        ],
    ],
  );

  /// Staged channels of [sourceId] so far.
  Future<int> stagedChannelCount(String sourceId) async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS n FROM channels_staging WHERE source_id = ?', variables: [Variable(sourceId)])
        .getSingle();
    return row.read<int>('n');
  }

  /// Swap the staged channels and [groups] in, in one transaction: a failed
  /// import (never committed) leaves the previous channels.
  Future<void> commitChannelImport(String sourceId, List<IptvGroup> groups) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM channels WHERE source_id = ?', [sourceId]);
      await db.customStatement(
        'INSERT INTO channels ($_channelColumns) SELECT $_channelColumns FROM channels_staging WHERE source_id = ?',
        [sourceId],
      );
      await db.customStatement('DELETE FROM channels_staging WHERE source_id = ?', [sourceId]);
      await db.customStatement('DELETE FROM groups WHERE source_id = ? AND kind = ?', [
        sourceId,
        IptvGroupKind.live.id,
      ]);
      await _insertGroups(sourceId, groups);
    });
  }

  Future<void> _insertGroups(String sourceId, List<IptvGroup> groups) =>
      _insertMany('INSERT OR REPLACE INTO groups (source_id, kind, id, name, sort_index) VALUES (?, ?, ?, ?, ?)', [
        for (final g in groups) [sourceId, g.kind.id, g.id, g.name, g.sortIndex],
      ]);

  Future<void> replaceGroups(String sourceId, IptvGroupKind kind, List<IptvGroup> groups) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM groups WHERE source_id = ? AND kind = ?', [sourceId, kind.id]);
      await _insertGroups(sourceId, groups);
    });
  }

  static Map<String, String> _headers(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {}
    return const {};
  }

  IptvChannel _channelFromRow(QueryRow row) {
    final overrideName = row.readNullable<String>('o_name');
    final original = row.read<String>('name');
    final manualEpg = row.readNullable<String>('o_epg');
    return IptvChannel(
      sourceId: row.read<String>('source_id'),
      id: row.read<String>('id'),
      name: overrideName == null || overrideName.isEmpty ? original : overrideName,
      originalName: original,
      number: row.readNullable<String>('o_number'),
      playlistNumber: row.readNullable<String>('number'),
      sortIndex: row.read<int>('sort_index'),
      group: row.readNullable<String>('grp'),
      logo: row.readNullable<String>('logo'),
      url: row.read<String>('url'),
      tvgId: row.readNullable<String>('tvg_id'),
      tvgName: row.readNullable<String>('tvg_name'),
      tvgShiftHours: row.readNullable<double>('tvg_shift'),
      catchupMode: IptvCatchupMode.parse(row.readNullable<String>('catchup')),
      catchupDays: row.readNullable<int>('catchup_days'),
      catchupSource: row.readNullable<String>('catchup_source'),
      radio: row.read<int>('radio') == 1,
      headers: _headers(row.readNullable<String>('headers')),
      xtreamId: row.readNullable<String>('xtream_id'),
      epgChannelId: manualEpg ?? row.readNullable<String>('epg_id'),
      manualEpgId: manualEpg,
      hidden: (row.readNullable<int>('o_hidden') ?? 0) == 1,
      shiftMinutes: row.readNullable<int>('o_shift') ?? 0,
    );
  }

  static const _channelSelect =
      'SELECT c.*, o.name AS o_name, o.number AS o_number, o.epg_id AS o_epg, o.hidden AS o_hidden, '
      'o.shift_minutes AS o_shift FROM channels c '
      'LEFT JOIN channel_overrides o ON o.source_id = c.source_id AND o.channel_id = c.id ';

  /// Every channel of [sourceId] in playlist order, overrides applied.
  Future<List<IptvChannel>> channels(String sourceId) async {
    final rows = await db
        .customSelect('$_channelSelect WHERE c.source_id = ? ORDER BY c.sort_index', variables: [Variable(sourceId)])
        .get();
    return rows.map(_channelFromRow).toList(growable: false);
  }

  Future<IptvChannel?> channel(String sourceId, String channelId) async {
    final row = await db
        .customSelect(
          '$_channelSelect WHERE c.source_id = ? AND c.id = ?',
          variables: [Variable(sourceId), Variable(channelId)],
        )
        .getSingleOrNull();
    return row == null ? null : _channelFromRow(row);
  }

  /// What guide matching needs of every channel, a page at a time (never
  /// the full rows of tens of thousands of channels at once).
  Future<void> forEachChannelGuideKey(
    String sourceId,
    void Function(
      ({String id, String name, String? originalName, String? tvgId, String? tvgName, String? manualEpgId}) key,
    )
    onKey, {
    int pageSize = 5000,
  }) async {
    var after = -1 << 62;
    while (true) {
      final rows = await db
          .customSelect(
            'SELECT c.id, c.name, c.tvg_id, c.tvg_name, c.sort_index, o.name AS o_name, o.epg_id AS o_epg '
            'FROM channels c LEFT JOIN channel_overrides o ON o.source_id = c.source_id AND o.channel_id = c.id '
            'WHERE c.source_id = ? AND c.sort_index > ? ORDER BY c.sort_index LIMIT ?',
            variables: [Variable(sourceId), Variable(after), Variable(pageSize)],
          )
          .get();
      for (final row in rows) {
        final original = row.read<String>('name');
        final override = row.readNullable<String>('o_name');
        final manual = row.readNullable<String>('o_epg');
        onKey((
          id: row.read<String>('id'),
          name: override == null || override.isEmpty ? original : override,
          originalName: original,
          tvgId: row.readNullable<String>('tvg_id'),
          tvgName: row.readNullable<String>('tvg_name'),
          manualEpgId: manual == null || manual.isEmpty ? null : manual,
        ));
      }
      if (rows.length < pageSize) return;
      after = rows.last.read<int>('sort_index');
    }
  }

  /// The channels with [ids] (overrides applied), in playlist order.
  Future<List<IptvChannel>> channelsByIds(String sourceId, List<String> ids) async {
    if (ids.isEmpty) return const [];
    final out = <IptvChannel>[];
    for (var i = 0; i < ids.length; i += 500) {
      final slice = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final rows = await db
          .customSelect(
            '$_channelSelect WHERE c.source_id = ? AND c.id IN (${List.filled(slice.length, '?').join(', ')})',
            variables: [Variable(sourceId), for (final id in slice) Variable(id)],
          )
          .get();
      out.addAll(rows.map(_channelFromRow));
    }
    final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    out.sort((a, b) => (order[a.id] ?? 0).compareTo(order[b.id] ?? 0));
    return out;
  }

  /// Ids of the channels matched to the guide channels [epgIds].
  Future<List<String>> channelIdsByEpg(String sourceId, Set<String> epgIds) async {
    if (epgIds.isEmpty) return const [];
    final list = epgIds.toList();
    final out = <String>[];
    for (var i = 0; i < list.length; i += 500) {
      final slice = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      final rows = await db
          .customSelect(
            'SELECT id FROM channels WHERE source_id = ? AND epg_id IN (${List.filled(slice.length, '?').join(', ')}) '
            'ORDER BY sort_index',
            variables: [Variable(sourceId), for (final id in slice) Variable(id)],
          )
          .get();
      out.addAll(rows.map((r) => r.read<String>('id')));
    }
    return out;
  }

  Future<int> channelCount(String sourceId) async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS n FROM channels WHERE source_id = ?', variables: [Variable(sourceId)])
        .getSingle();
    return row.read<int>('n');
  }

  /// Channels whose name contains [query] (case-insensitive), playlist order.
  Future<List<IptvChannel>> searchChannels(String sourceId, String query, {int limit = 50}) async {
    final rows = await db
        .customSelect(
          '$_channelSelect WHERE c.source_id = ? AND (c.name_lower LIKE ? ESCAPE \'\\\' OR lower(o.name) LIKE ? ESCAPE \'\\\') '
          'ORDER BY c.sort_index LIMIT ?',
          variables: [Variable(sourceId), Variable(_like(query)), Variable(_like(query)), Variable(limit)],
        )
        .get();
    return rows.map(_channelFromRow).toList(growable: false);
  }

  static String _like(String query) {
    final escaped = query.toLowerCase().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    return '%$escaped%';
  }

  Future<void> setChannelEpgIds(String sourceId, Map<String, String?> epgIdByChannel) async {
    final entries = epgIdByChannel.entries.toList();
    for (var i = 0; i < entries.length; i += _batchSize) {
      final slice = entries.sublist(i, i + _batchSize > entries.length ? entries.length : i + _batchSize);
      await db.batch((b) {
        for (final e in slice) {
          b.customStatement('UPDATE channels SET epg_id = ? WHERE source_id = ? AND id = ?', [
            e.value,
            sourceId,
            e.key,
          ]);
        }
      });
    }
  }

  /// Save the user's changes to one channel. A null field clears that change.
  Future<void> setChannelOverride(
    String sourceId,
    String channelId, {
    required bool hidden,
    String? name,
    String? number,
    String? epgId,
    int shiftMinutes = 0,
  }) async {
    final empty =
        !hidden && (name ?? '').isEmpty && (number ?? '').isEmpty && (epgId ?? '').isEmpty && shiftMinutes == 0;
    if (empty) {
      await db.customStatement('DELETE FROM channel_overrides WHERE source_id = ? AND channel_id = ?', [
        sourceId,
        channelId,
      ]);
      return;
    }
    await db.customStatement(
      'INSERT OR REPLACE INTO channel_overrides (source_id, channel_id, hidden, name, number, epg_id, shift_minutes) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        sourceId,
        channelId,
        hidden ? 1 : 0,
        (name ?? '').isEmpty ? null : name,
        (number ?? '').isEmpty ? null : number,
        (epgId ?? '').isEmpty ? null : epgId,
        shiftMinutes,
      ],
    );
  }

  // ---- groups -------------------------------------------------------------

  /// Groups of [kind] in display order (the user's order, then the source's),
  /// each with its item count.
  Future<List<IptvGroup>> groups(String sourceId, IptvGroupKind kind, {bool withCounts = true}) async {
    // One grouped count (a correlated count per group scanned the whole
    // source once per group: minutes with 200k movies in 1000 categories).
    final countJoin = !withCounts
        ? ''
        : kind == IptvGroupKind.live
        ? 'LEFT JOIN (SELECT grp AS cid, COUNT(*) AS n FROM channels WHERE source_id = ?1 GROUP BY grp) cnt '
              'ON cnt.cid = g.id '
        : 'LEFT JOIN (SELECT category_id AS cid, COUNT(*) AS n FROM vod WHERE source_id = ?1 AND kind = ?2 '
              'GROUP BY category_id) cnt ON cnt.cid = g.id ';
    final rows = await db
        .customSelect(
          'SELECT g.*, o.hidden AS o_hidden, o.sort_index AS o_sort${withCounts ? ', cnt.n AS n' : ''} FROM groups g '
          'LEFT JOIN group_overrides o ON o.source_id = g.source_id AND o.kind = g.kind AND o.group_id = g.id '
          '$countJoin'
          'WHERE g.source_id = ?1 AND g.kind = ?2 ORDER BY COALESCE(o.sort_index, 1000000 + g.sort_index)',
          variables: [Variable(sourceId), Variable(kind.id)],
        )
        .get();
    return [
      for (final row in rows)
        IptvGroup(
          kind: kind,
          id: row.read<String>('id'),
          name: row.read<String>('name'),
          sortIndex: row.readNullable<int>('o_sort') ?? 1000000 + row.read<int>('sort_index'),
          hidden: (row.readNullable<int>('o_hidden') ?? 0) == 1,
          count: withCounts ? row.readNullable<int>('n') ?? 0 : 0,
        ),
    ];
  }

  Future<void> setGroupHidden(String sourceId, IptvGroupKind kind, String groupId, bool hidden) async {
    await db.customStatement(
      'INSERT INTO group_overrides (source_id, kind, group_id, hidden) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (source_id, kind, group_id) DO UPDATE SET hidden = excluded.hidden',
      [sourceId, kind.id, groupId, hidden ? 1 : 0],
    );
  }

  /// Store [orderedGroupIds] as the user's order of [kind]'s groups.
  Future<void> setGroupOrder(String sourceId, IptvGroupKind kind, List<String> orderedGroupIds) async {
    await db.transaction(() async {
      for (var i = 0; i < orderedGroupIds.length; i++) {
        await db.customStatement(
          'INSERT INTO group_overrides (source_id, kind, group_id, sort_index) VALUES (?, ?, ?, ?) '
          'ON CONFLICT (source_id, kind, group_id) DO UPDATE SET sort_index = excluded.sort_index',
          [sourceId, kind.id, orderedGroupIds[i], i],
        );
      }
    });
  }

  // ---- guide --------------------------------------------------------------

  /// Start a guide import: clears this source's staging rows.
  Future<void> beginProgrammeImport(String sourceId) =>
      db.customStatement('DELETE FROM programmes_staging WHERE source_id = ?', [sourceId]);

  Future<void> stageProgrammes(String sourceId, List<IptvProgramme> programmes) => _insertMany(
    'INSERT INTO programmes_staging (source_id, channel, start, stop, title, sub_title, descr, category, icon, '
    'episode, season, ep, rating, year, title_lower, is_new) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      for (final p in programmes)
        [
          sourceId,
          p.epgChannelId,
          p.start,
          p.stop,
          p.title,
          p.subTitle,
          p.description,
          p.category,
          p.icon,
          p.episode,
          p.season,
          p.episodeNumber,
          p.rating,
          p.year,
          p.title.toLowerCase(),
          p.isNew ? 1 : 0,
        ],
    ],
  );

  /// Swap the staged guide in for the source's guide in one transaction, so
  /// the guide is never seen half imported. Returns the rows now stored.
  Future<int> commitProgrammeImport(String sourceId) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM programmes WHERE source_id = ?', [sourceId]);
      await db.customStatement(
        'INSERT INTO programmes (source_id, channel, start, stop, title, sub_title, descr, category, icon, episode, season, ep, rating, year, title_lower, is_new) '
        'SELECT DISTINCT source_id, channel, start, stop, title, sub_title, descr, category, icon, episode, season, ep, rating, year, title_lower, is_new '
        'FROM programmes_staging WHERE source_id = ?',
        [sourceId],
      );
      await db.customStatement('DELETE FROM programmes_staging WHERE source_id = ?', [sourceId]);
    });
    final row = await db
        .customSelect('SELECT COUNT(*) AS n FROM programmes WHERE source_id = ?', variables: [Variable(sourceId)])
        .getSingle();
    return row.read<int>('n');
  }

  Future<void> replaceEpgChannels(
    String sourceId,
    List<({String id, String displayName, String norm, String? icon})> rows,
  ) async {
    await beginEpgChannelImport(sourceId);
    await stageEpgChannels(sourceId, rows);
    await commitEpgChannelImport(sourceId);
  }

  Future<void> beginEpgChannelImport(String sourceId) =>
      db.customStatement('DELETE FROM epg_channels_staging WHERE source_id = ?', [sourceId]);

  Future<void> stageEpgChannels(
    String sourceId,
    List<({String id, String displayName, String norm, String? icon})> rows,
  ) => _insertMany(
    'INSERT OR IGNORE INTO epg_channels_staging (source_id, id, display_name, name_norm, icon) VALUES (?, ?, ?, ?, ?)',
    [
      for (final r in rows) [sourceId, r.id, r.displayName, r.norm, r.icon],
    ],
  );

  /// Swap the staged guide channels in (in the order they were staged).
  Future<void> commitEpgChannelImport(String sourceId) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM epg_channels WHERE source_id = ?', [sourceId]);
      await db.customStatement(
        'INSERT OR IGNORE INTO epg_channels (source_id, id, display_name, name_norm, icon) '
        'SELECT source_id, id, display_name, name_norm, icon FROM epg_channels_staging WHERE source_id = ? '
        'ORDER BY rowid',
        [sourceId],
      );
      await db.customStatement('DELETE FROM epg_channels_staging WHERE source_id = ?', [sourceId]);
    });
  }

  /// Guide channels: id → first display name, and normalised name → id.
  Future<({Map<String, String> names, Map<String, String> byNorm, Map<String, String?> icons})> epgChannels(
    String sourceId,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT id, display_name, name_norm, icon FROM epg_channels WHERE source_id = ? ORDER BY rowid',
          variables: [Variable(sourceId)],
        )
        .get();
    final names = <String, String>{};
    final byNorm = <String, String>{};
    final icons = <String, String?>{};
    for (final row in rows) {
      final id = row.read<String>('id');
      names.putIfAbsent(id, () => row.read<String>('display_name'));
      icons.putIfAbsent(id, () => row.readNullable<String>('icon'));
      final norm = row.read<String>('name_norm');
      if (norm.isNotEmpty) byNorm.putIfAbsent(norm, () => id);
    }
    return (names: names, byNorm: byNorm, icons: icons);
  }

  IptvProgramme _programmeFromRow(QueryRow row) => IptvProgramme(
    epgChannelId: row.read<String>('channel'),
    start: row.read<int>('start'),
    stop: row.read<int>('stop'),
    title: row.read<String>('title'),
    subTitle: row.readNullable<String>('sub_title'),
    description: row.readNullable<String>('descr'),
    category: row.readNullable<String>('category'),
    icon: row.readNullable<String>('icon'),
    episode: row.readNullable<String>('episode'),
    season: row.readNullable<int>('season'),
    episodeNumber: row.readNullable<int>('ep'),
    rating: row.readNullable<String>('rating'),
    year: row.readNullable<int>('year'),
    isNew: (row.readNullable<int>('is_new') ?? 0) == 1,
  );

  /// Raw (unshifted) programmes overlapping `[from, to)` (epoch seconds),
  /// optionally for some guide channels only.
  Future<List<IptvProgramme>> programmes(
    String sourceId, {
    required int from,
    required int to,
    Set<String>? channels,
  }) async {
    if (channels != null && channels.isEmpty) return const [];
    final out = <IptvProgramme>[];
    if (channels == null) {
      final rows = await db
          .customSelect(
            'SELECT * FROM programmes WHERE source_id = ? AND stop > ? AND start < ? ORDER BY channel, start',
            variables: [Variable(sourceId), Variable(from), Variable(to)],
          )
          .get();
      out.addAll(rows.map(_programmeFromRow));
      return out;
    }
    final list = channels.toList();
    const chunk = 400;
    for (var i = 0; i < list.length; i += chunk) {
      final slice = list.sublist(i, i + chunk > list.length ? list.length : i + chunk);
      final marks = List.filled(slice.length, '?').join(', ');
      final rows = await db
          .customSelect(
            'SELECT * FROM programmes WHERE source_id = ? AND channel IN ($marks) AND stop > ? AND start < ? '
            'ORDER BY channel, start',
            variables: [Variable(sourceId), for (final c in slice) Variable(c), Variable(from), Variable(to)],
          )
          .get();
      out.addAll(rows.map(_programmeFromRow));
    }
    return out;
  }

  /// Programmes whose title contains [query], from [from] on.
  Future<List<IptvProgramme>> searchProgrammes(
    String sourceId,
    String query, {
    required int from,
    int limit = 50,
  }) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM programmes WHERE source_id = ? AND stop > ? AND title_lower LIKE ? ESCAPE \'\\\' '
          'ORDER BY start LIMIT ?',
          variables: [Variable(sourceId), Variable(from), Variable(_like(query)), Variable(limit)],
        )
        .get();
    return rows.map(_programmeFromRow).toList(growable: false);
  }

  Future<int> programmeCount(String sourceId) async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS n FROM programmes WHERE source_id = ?', variables: [Variable(sourceId)])
        .getSingle();
    return row.read<int>('n');
  }

  /// Drop programmes that ended before [before] (epoch seconds).
  Future<void> pruneProgrammes(String sourceId, int before) =>
      db.customStatement('DELETE FROM programmes WHERE source_id = ? AND stop < ?', [sourceId, before]);

  // ---- VOD -----------------------------------------------------------------

  static const _vodColumns =
      'source_id, kind, id, name, name_lower, category_id, poster, rating, year, added, '
      'ext, plot, genre, sort_index, url, headers';

  /// Replace a source's movies or series with a fresh import (small lists;
  /// imports stage in batches: [beginVodImport]).
  Future<void> replaceVod(String sourceId, IptvGroupKind kind, List<IptvVodRow> rows, List<IptvGroup> groups) async {
    await beginVodImport(sourceId, kind);
    await stageVod(sourceId, kind, rows);
    await commitVodImport(sourceId, kind, groups);
  }

  Future<void> beginVodImport(String sourceId, IptvGroupKind kind) =>
      db.customStatement('DELETE FROM vod_staging WHERE source_id = ? AND kind = ?', [sourceId, kind.id]);

  Future<void> stageVod(String sourceId, IptvGroupKind kind, List<IptvVodRow> rows) => _insertMany(
    'INSERT OR REPLACE INTO vod_staging ($_vodColumns) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      for (final r in rows)
        [
          sourceId,
          kind.id,
          r.id,
          r.name,
          r.name.toLowerCase(),
          r.categoryId,
          r.poster,
          r.rating,
          r.year,
          r.added,
          r.extension,
          r.plot,
          r.genre,
          r.sortIndex,
          r.url,
          r.headers.isEmpty ? null : jsonEncode(r.headers),
        ],
    ],
  );

  /// Swap the staged rows of [kind] and its [groups] in, in one transaction.
  Future<void> commitVodImport(String sourceId, IptvGroupKind kind, List<IptvGroup> groups) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM vod WHERE source_id = ? AND kind = ?', [sourceId, kind.id]);
      await db.customStatement(
        'INSERT INTO vod ($_vodColumns) SELECT $_vodColumns FROM vod_staging WHERE source_id = ? AND kind = ?',
        [sourceId, kind.id],
      );
      await db.customStatement('DELETE FROM vod_staging WHERE source_id = ? AND kind = ?', [sourceId, kind.id]);
      await db.customStatement('DELETE FROM groups WHERE source_id = ? AND kind = ?', [sourceId, kind.id]);
      await _insertGroups(sourceId, groups);
    });
  }

  IptvVodRow _vodFromRow(QueryRow row) => IptvVodRow(
    sourceId: row.read<String>('source_id'),
    kind: IptvGroupKind.parse(row.read<String>('kind')),
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    sortIndex: row.read<int>('sort_index'),
    categoryId: row.readNullable<String>('category_id'),
    poster: row.readNullable<String>('poster'),
    rating: row.readNullable<double>('rating'),
    year: row.readNullable<int>('year'),
    added: row.readNullable<int>('added'),
    extension: row.readNullable<String>('ext'),
    plot: row.readNullable<String>('plot'),
    genre: row.readNullable<String>('genre'),
    url: row.readNullable<String>('url'),
    headers: _headers(row.readNullable<String>('headers')),
  );

  static String _vodOrder(String? sort, bool descending) {
    final dir = descending ? 'DESC' : 'ASC';
    return switch (sort) {
      'title' => 'v.name_lower $dir',
      // Plain `added` (NULLs sort lowest, as 0 did) so `vod_added` serves it.
      'added' => 'v.added $dir, v.sort_index',
      'year' => 'COALESCE(v.year, 0) $dir, v.name_lower',
      'rating' => 'COALESCE(v.rating, 0) $dir, v.name_lower',
      _ => 'v.sort_index ${descending ? 'DESC' : 'ASC'}',
    };
  }

  /// One page of movies or series, hidden categories left out.
  Future<({List<IptvVodRow> rows, int total})> vodPage(
    String sourceId,
    IptvGroupKind kind, {
    required int offset,
    required int limit,
    Set<String>? categoryIds,
    String? search,
    String? nameStartsWith,
    String? sort,
    bool descending = false,
    Set<String> hiddenCategoryIds = const {},
  }) async {
    final where = <String>['v.source_id = ?', 'v.kind = ?'];
    final vars = <Variable>[Variable(sourceId), Variable(kind.id)];
    if (categoryIds != null && categoryIds.isNotEmpty) {
      where.add('v.category_id IN (${List.filled(categoryIds.length, '?').join(', ')})');
      vars.addAll(categoryIds.map(Variable.new));
    }
    if (hiddenCategoryIds.isNotEmpty) {
      where.add(
        '(v.category_id IS NULL OR v.category_id NOT IN (${List.filled(hiddenCategoryIds.length, '?').join(', ')}))',
      );
      vars.addAll(hiddenCategoryIds.map(Variable.new));
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add("v.name_lower LIKE ? ESCAPE '\\'");
      vars.add(Variable(_like(search.trim())));
    }
    if (nameStartsWith != null && nameStartsWith.isNotEmpty) {
      if (nameStartsWith == '#') {
        where.add("NOT (substr(v.name_lower, 1, 1) BETWEEN 'a' AND 'z')");
      } else {
        where.add('v.name_lower >= ? AND v.name_lower < ?');
        final lower = nameStartsWith.toLowerCase();
        vars
          ..add(Variable(lower))
          ..add(Variable(String.fromCharCodes([...lower.codeUnits.take(lower.length - 1), lower.codeUnits.last + 1])));
      }
    }
    final whereSql = where.join(' AND ');
    final total = await db.customSelect('SELECT COUNT(*) AS n FROM vod v WHERE $whereSql', variables: vars).getSingle();
    final rows = await db
        .customSelect(
          'SELECT v.* FROM vod v WHERE $whereSql ORDER BY ${_vodOrder(sort, descending)} LIMIT ? OFFSET ?',
          variables: [...vars, Variable(limit), Variable(offset)],
        )
        .get();
    return (rows: rows.map(_vodFromRow).toList(growable: false), total: total.read<int>('n'));
  }

  Future<IptvVodRow?> vodRow(String sourceId, IptvGroupKind kind, String id) async {
    final row = await db
        .customSelect(
          'SELECT v.* FROM vod v WHERE v.source_id = ? AND v.kind = ? AND v.id = ?',
          variables: [Variable(sourceId), Variable(kind.id), Variable(id)],
        )
        .getSingleOrNull();
    return row == null ? null : _vodFromRow(row);
  }

  Future<int> vodCount(String sourceId, IptvGroupKind kind) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM vod WHERE source_id = ? AND kind = ?',
          variables: [Variable(sourceId), Variable(kind.id)],
        )
        .getSingle();
    return row.read<int>('n');
  }

  // ---- favourites and recents -------------------------------------------

  Future<List<String>> favoriteChannelIds(String sourceId) async {
    final rows = await db
        .customSelect(
          'SELECT channel_id FROM favorites WHERE source_id = ? ORDER BY sort_index',
          variables: [Variable(sourceId)],
        )
        .get();
    return [for (final r in rows) r.read<String>('channel_id')];
  }

  Future<void> setFavoriteChannelIds(String sourceId, List<String> channelIds) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM favorites WHERE source_id = ?', [sourceId]);
      for (var i = 0; i < channelIds.length; i++) {
        await db.customStatement(
          'INSERT OR REPLACE INTO favorites (source_id, channel_id, sort_index) VALUES (?, ?, ?)',
          [sourceId, channelIds[i], i],
        );
      }
    });
  }

  static const maxRecents = 30;

  Future<void> addRecent(String sourceId, String channelId, {DateTime? at}) async {
    await db.customStatement('INSERT OR REPLACE INTO recents (source_id, channel_id, watched_at) VALUES (?, ?, ?)', [
      sourceId,
      channelId,
      (at ?? DateTime.now()).millisecondsSinceEpoch,
    ]);
    await db.customStatement(
      'DELETE FROM recents WHERE source_id = ? AND channel_id NOT IN '
      '(SELECT channel_id FROM recents WHERE source_id = ? ORDER BY watched_at DESC LIMIT $maxRecents)',
      [sourceId, sourceId],
    );
  }

  Future<List<String>> recentChannelIds(String sourceId) async {
    final rows = await db
        .customSelect(
          'SELECT channel_id FROM recents WHERE source_id = ? ORDER BY watched_at DESC',
          variables: [Variable(sourceId)],
        )
        .get();
    return [for (final r in rows) r.read<String>('channel_id')];
  }

  // ---- progress -----------------------------------------------------------

  Future<void> saveProgress(
    String sourceId,
    String itemId, {
    required int positionMs,
    required int durationMs,
    required bool watched,
    Map<String, Object?> meta = const {},
    DateTime? at,
  }) => db.customStatement(
    'INSERT OR REPLACE INTO progress (source_id, item_id, position_ms, duration_ms, watched, updated_at, meta) '
    'VALUES (?, ?, ?, ?, ?, ?, ?)',
    [
      sourceId,
      itemId,
      positionMs,
      durationMs,
      watched ? 1 : 0,
      (at ?? DateTime.now()).millisecondsSinceEpoch,
      meta.isEmpty ? null : jsonEncode(meta),
    ],
  );

  IptvProgress _progressFromRow(QueryRow row) {
    Map<String, Object?> meta = const {};
    final raw = row.readNullable<String>('meta');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) meta = decoded;
      } catch (_) {}
    }
    return IptvProgress(
      itemId: row.read<String>('item_id'),
      positionMs: row.read<int>('position_ms'),
      durationMs: row.read<int>('duration_ms'),
      watched: row.read<int>('watched') == 1,
      updatedAt: row.read<int>('updated_at'),
      meta: meta,
    );
  }

  Future<IptvProgress?> progress(String sourceId, String itemId) async {
    final row = await db
        .customSelect(
          'SELECT * FROM progress WHERE source_id = ? AND item_id = ?',
          variables: [Variable(sourceId), Variable(itemId)],
        )
        .getSingleOrNull();
    return row == null ? null : _progressFromRow(row);
  }

  Future<Map<String, IptvProgress>> progressFor(String sourceId, Iterable<String> itemIds) async {
    final ids = itemIds.toSet().toList();
    final out = <String, IptvProgress>{};
    const chunk = 400;
    for (var i = 0; i < ids.length; i += chunk) {
      final slice = ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk);
      final rows = await db
          .customSelect(
            'SELECT * FROM progress WHERE source_id = ? AND item_id IN (${List.filled(slice.length, '?').join(', ')})',
            variables: [Variable(sourceId), ...slice.map(Variable.new)],
          )
          .get();
      for (final row in rows) {
        final p = _progressFromRow(row);
        out[p.itemId] = p;
      }
    }
    return out;
  }

  /// Started, unfinished items, most recent first.
  Future<List<IptvProgress>> inProgress(String sourceId, {int limit = 20}) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM progress WHERE source_id = ? AND watched = 0 AND position_ms > 0 '
          'ORDER BY updated_at DESC LIMIT ?',
          variables: [Variable(sourceId), Variable(limit)],
        )
        .get();
    return rows.map(_progressFromRow).toList(growable: false);
  }

  Future<void> deleteProgress(String sourceId, String itemId) =>
      db.customStatement('DELETE FROM progress WHERE source_id = ? AND item_id = ?', [sourceId, itemId]);

  // ---- reminders ----------------------------------------------------------

  Future<void> addReminder(IptvReminder r) => db.customStatement(
    'INSERT OR REPLACE INTO reminders (source_id, channel_id, start, stop, title, channel_name) VALUES (?, ?, ?, ?, ?, ?)',
    [r.sourceId, r.channelId, r.start, r.stop, r.title, r.channelName],
  );

  Future<void> removeReminder(String sourceId, String channelId, int start) => db.customStatement(
    'DELETE FROM reminders WHERE source_id = ? AND channel_id = ? AND start = ?',
    [sourceId, channelId, start],
  );

  Future<List<IptvReminder>> reminders({String? sourceId, int? after}) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM reminders WHERE (? IS NULL OR source_id = ?) AND (? IS NULL OR start >= ?) ORDER BY start',
          variables: [Variable(sourceId), Variable(sourceId), Variable(after), Variable(after)],
        )
        .get();
    return [
      for (final r in rows)
        IptvReminder(
          sourceId: r.read<String>('source_id'),
          channelId: r.read<String>('channel_id'),
          start: r.read<int>('start'),
          stop: r.read<int>('stop'),
          title: r.read<String>('title'),
          channelName: r.readNullable<String>('channel_name'),
        ),
    ];
  }

  Future<void> pruneReminders(int before) => db.customStatement('DELETE FROM reminders WHERE start < ?', [before]);

  // ---- recordings ---------------------------------------------------------

  Future<void> putRecording(IptvRecordingRow r) => db.customStatement(
    'INSERT OR REPLACE INTO recordings (id, source_id, channel_id, channel_name, title, start, stop, state, path, '
    'bytes, error, rule_id, episode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      r.id,
      r.sourceId,
      r.channelId,
      r.channelName,
      r.title,
      r.start,
      r.stop,
      r.state.name,
      r.path,
      r.bytes,
      r.error,
      r.ruleId,
      r.episode,
    ],
  );

  Future<List<IptvRecordingRow>> recordings({String? sourceId}) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM recordings WHERE (? IS NULL OR source_id = ?) ORDER BY start DESC',
          variables: [Variable(sourceId), Variable(sourceId)],
        )
        .get();
    return [
      for (final r in rows)
        IptvRecordingRow(
          id: r.read<String>('id'),
          sourceId: r.read<String>('source_id'),
          channelId: r.read<String>('channel_id'),
          channelName: r.readNullable<String>('channel_name'),
          title: r.read<String>('title'),
          start: r.read<int>('start'),
          stop: r.read<int>('stop'),
          state: IptvRecordingState.values.firstWhere(
            (s) => s.name == r.read<String>('state'),
            orElse: () => IptvRecordingState.failed,
          ),
          path: r.readNullable<String>('path'),
          bytes: r.read<int>('bytes'),
          error: r.readNullable<String>('error'),
          ruleId: r.readNullable<String>('rule_id'),
          episode: r.readNullable<String>('episode'),
        ),
    ];
  }

  // ---- series recording rules ---------------------------------------------

  Future<void> putRule(IptvRecordingRule rule) => db.customStatement(
    'INSERT OR REPLACE INTO recording_rules (id, source_id, title, title_lower, channel_id, channel_name, any_channel, '
    'new_only, keep_last, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      rule.id,
      rule.sourceId,
      rule.title,
      rule.title.toLowerCase(),
      rule.channelId,
      rule.channelName,
      rule.anyChannel ? 1 : 0,
      rule.newOnly ? 1 : 0,
      rule.keepLast,
      rule.createdAt,
    ],
  );

  Future<List<IptvRecordingRule>> rules({String? sourceId}) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM recording_rules WHERE (? IS NULL OR source_id = ?) ORDER BY title_lower',
          variables: [Variable(sourceId), Variable(sourceId)],
        )
        .get();
    return [
      for (final r in rows)
        IptvRecordingRule(
          id: r.read<String>('id'),
          sourceId: r.read<String>('source_id'),
          title: r.read<String>('title'),
          channelId: r.read<String>('channel_id'),
          channelName: r.readNullable<String>('channel_name'),
          anyChannel: r.read<int>('any_channel') == 1,
          newOnly: r.read<int>('new_only') == 1,
          keepLast: r.read<int>('keep_last'),
          createdAt: r.read<int>('created_at'),
        ),
    ];
  }

  Future<void> deleteRule(String id) => db.customStatement('DELETE FROM recording_rules WHERE id = ?', [id]);

  /// Future programmes titled [titleLower] (raw times), optionally on some
  /// guide channels only.
  Future<List<IptvProgramme>> programmesTitled(String sourceId, String titleLower, {required int from}) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM programmes WHERE source_id = ? AND title_lower = ? AND stop > ? ORDER BY start',
          variables: [Variable(sourceId), Variable(titleLower), Variable(from)],
        )
        .get();
    return rows.map(_programmeFromRow).toList(growable: false);
  }

  Future<void> deleteRecording(String id) => db.customStatement('DELETE FROM recordings WHERE id = ?', [id]);

  // ---- sync state and metadata -------------------------------------------

  Future<void> recordSync(String sourceId, String kind, {required bool ok, String? error, int count = 0}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (ok) {
      await db.customStatement(
        'INSERT OR REPLACE INTO sync_state (source_id, kind, last_success, last_attempt, error, count) '
        'VALUES (?, ?, ?, ?, NULL, ?)',
        [sourceId, kind, now, now, count],
      );
    } else {
      await db.customStatement(
        'INSERT INTO sync_state (source_id, kind, last_attempt, error) VALUES (?, ?, ?, ?) '
        'ON CONFLICT (source_id, kind) DO UPDATE SET last_attempt = excluded.last_attempt, error = excluded.error',
        [sourceId, kind, now, error],
      );
    }
  }

  Future<IptvSyncRecord> syncRecord(String sourceId, String kind) async {
    final row = await db
        .customSelect(
          'SELECT * FROM sync_state WHERE source_id = ? AND kind = ?',
          variables: [Variable(sourceId), Variable(kind)],
        )
        .getSingleOrNull();
    if (row == null) return const IptvSyncRecord();
    DateTime? ms(int? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
    return IptvSyncRecord(
      lastSuccess: ms(row.readNullable<int>('last_success')),
      lastAttempt: ms(row.readNullable<int>('last_attempt')),
      error: row.readNullable<String>('error'),
      count: row.read<int>('count'),
    );
  }

  Future<void> putMeta(String sourceId, String key, String? value) => value == null
      ? db.customStatement('DELETE FROM source_meta WHERE source_id = ? AND key = ?', [sourceId, key])
      : db.customStatement('INSERT OR REPLACE INTO source_meta (source_id, key, value) VALUES (?, ?, ?)', [
          sourceId,
          key,
          value,
        ]);

  Future<String?> meta(String sourceId, String key) async {
    final row = await db
        .customSelect(
          'SELECT value FROM source_meta WHERE source_id = ? AND key = ?',
          variables: [Variable(sourceId), Variable(key)],
        )
        .getSingleOrNull();
    return row?.readNullable<String>('value');
  }

  /// Forget everything of [sourceId]: imported data and the user's own
  /// (favourites, overrides, progress, reminders, recordings rows). Recorded
  /// files are deleted by the caller, which knows their paths.
  Future<void> deleteSource(String sourceId) async {
    await db.transaction(() async {
      for (final table in const [
        'channels',
        'channels_staging',
        'groups',
        'programmes',
        'programmes_staging',
        'epg_channels',
        'epg_channels_staging',
        'vod',
        'vod_staging',
        'channel_overrides',
        'group_overrides',
        'favorites',
        'recents',
        'progress',
        'reminders',
        'recordings',
        'recording_rules',
        'sync_state',
        'source_meta',
      ]) {
        await db.customStatement('DELETE FROM $table WHERE source_id = ?', [sourceId]);
      }
    });
    appLogger.i('[iptv] removed the stored data of a source');
  }

  /// Source ids that still have rows (for pruning after removals).
  Future<Set<String>> storedSourceIds() async {
    final rows = await db
        .customSelect(
          'SELECT source_id FROM channels UNION SELECT source_id FROM vod UNION SELECT source_id FROM progress '
          'UNION SELECT source_id FROM sync_state',
        )
        .get();
    return {for (final r in rows) r.read<String>('source_id')};
  }
}
