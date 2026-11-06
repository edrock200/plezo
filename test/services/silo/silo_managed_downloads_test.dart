import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/download_resolution.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_download_registry.dart';
import 'package:plezy/services/silo/silo_managed_downloads.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

final _connection = SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com/base',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

const _scope = 'srv-1/1/p-owner';
const _movieKey = 'srv-1:movie:m1';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _capability({
  bool transcode = true,
  bool revokedRemovesLocal = true,
  bool bounded = true,
  bool enabled = true,
}) => {
  'revision': '1',
  'state': enabled ? 'available' : 'disabled',
  'allowed': true,
  'enabled': enabled,
  'download_allowed': true,
  'quality_presets': ['original', '20mbps', '10mbps', '5mbps', '2mbps', '1mbps'],
  'quality_options': [
    {'preset': 'original'},
    {'preset': '20mbps', 'bitrate_kbps': 20000, 'max_height': 2160},
    {'preset': '10mbps', 'bitrate_kbps': 10000, 'max_height': 1080},
    {'preset': '5mbps', 'bitrate_kbps': 5000, 'max_height': 1080},
    {'preset': '2mbps', 'bitrate_kbps': 2000, 'max_height': 720},
    {'preset': '1mbps', 'bitrate_kbps': 1000, 'max_height': 480},
  ],
  'transcode_enabled': transcode,
  'transcode_user_allowed': true,
  'ordered_status': true,
  'file_delivery': true,
  'bounded_creation': bounded,
  'direct_download_links': true,
  'prepare_again': true,
  'revoked_removes_local': revokedRemovesLocal,
};

Map<String, dynamic> _entry({
  String id = 'dl-1',
  String status = 'ready',
  String quality = 'original',
  String format = 'original',
  int revision = 1,
  String fileId = '42',
  String contentId = 'movie:m1',
  String? episodeId,
  Map<String, dynamic>? preparation,
}) => {
  'id': id,
  'content_id': contentId,
  'episode_id': ?episodeId,
  'device_id': 'dev-1',
  'media_file_id': fileId,
  'file_size': 1000,
  'bytes_sent': 0,
  'kind': 'queued',
  'status': status,
  'quality': quality,
  'effective_quality': format == 'original' ? 'original' : quality,
  'delivery_format': format,
  'target_bitrate_kbps': 0,
  'revision': revision,
  'created_at': '2026-11-01T00:00:00Z',
  'preparation': ?preparation,
};

/// A Silo server with the managed registry, recording what Plezilo sends.
class _Server {
  bool capabilityRoute = true;
  Map<String, dynamic> capability = _capability();
  final entries = <Map<String, dynamic>>[];
  final requests = <http.Request>[];

  /// What the next POST /downloads creates.
  Map<String, dynamic> Function(Map<String, dynamic> body) onCreate = (body) => _entry(
    quality: body['quality'] as String,
    fileId: body['media_file_id'] as String,
    contentId: body['content_id'] as String,
    episodeId: body['episode_id'] as String?,
  );
  int? createStatus;
  bool failDeletes = false;

  Iterable<http.Request> calls(String method, String pathEnd) =>
      requests.where((r) => r.method == method && Uri.decodeComponent(r.url.path).endsWith(pathEnd));

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = Uri.decodeComponent(request.url.path);
    if (path.endsWith('/watch/movie:m1') || path.endsWith('/watch/ep:e1')) {
      return _json({
        'content_id': path.endsWith('ep:e1') ? 'ep:e1' : 'movie:m1',
        'versions': [
          {'file_id': '42', 'container': 'mkv', 'subtitle_tracks': const []},
        ],
      });
    }
    if (path.endsWith('/direct-download/links')) {
      return _json({'url': '/api/v2/direct-download?file_id=42&dl=link', 'expires_at': '2030-01-01T00:00:00Z'});
    }
    if (path.endsWith('/capabilities/downloads')) {
      return capabilityRoute ? _json(capability) : _json({'title': 'not found'}, 404);
    }
    if (path.endsWith('/api/v2/downloads') && request.method == 'GET') {
      return _json({
        'items': entries,
        'page': {'has_more': false},
      });
    }
    if (path.endsWith('/api/v2/downloads') && request.method == 'POST') {
      if (createStatus != null) return _json({'title': 'refused', 'status': createStatus}, createStatus!);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final created = onCreate(body);
      entries
        ..removeWhere((e) => e['id'] == created['id'])
        ..add(created);
      return _json({
        'items': [created],
        'skipped': const [],
        'page': {'has_more': false},
      }, 202);
    }
    final entryMatch = RegExp(r'/api/v2/downloads/([^/]+)(/prepare)?$').firstMatch(path);
    if (entryMatch != null) {
      final id = entryMatch.group(1)!;
      final entry = entries.where((e) => e['id'] == id).firstOrNull;
      if (request.method == 'DELETE') {
        if (failDeletes) return _json({'title': 'busy'}, 503);
        if (entry == null) return _json({'title': 'not found'}, 404);
        entries.remove(entry);
        return http.Response('', 204);
      }
      if (entry == null) return _json({'title': 'not found'}, 404);
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        entry['status'] = body['status'];
        return _json(entry);
      }
      if (request.method == 'POST' && entryMatch.group(2) != null) return _json(entry);
    }
    return _json({'title': 'not found'}, 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Server server;
  late SiloClient client;
  late MemorySiloManagedDownloadPersistence persistence;
  final revoked = <String>[];
  final managed = SiloManagedDownloads.instance;

  final movie = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    persistence = MemorySiloManagedDownloadPersistence();
    managed.resetForTesting(persistence: persistence);
    revoked.clear();
    managed.onRevoked = (globalKey) async {
      revoked.add(globalKey);
      await managed.localCopyRemoved(globalKey);
    };
    server = _Server();
    client = SiloClient.forTesting(_connection, headers: _headers, httpClient: MockClient(server.handle));
  });

  tearDown(() => managed.resetForTesting());

  group('capability', () {
    test('parses presets with their labels, in ladder order', () {
      final cap = SiloDownloadCapability.fromJson(_capability());
      expect(cap.managesDownloads, isTrue);
      expect(cap.allowedQualities.map((q) => q.preset), ['original', '20mbps', '10mbps', '5mbps', '2mbps', '1mbps']);
      expect(cap.allowedQualities.map((q) => q.label), [
        'Original quality',
        '20 Mbps · up to 4K',
        '10 Mbps · up to 1080p',
        '5 Mbps · up to 1080p',
        '2 Mbps · up to 720p',
        '1 Mbps · up to 480p',
      ]);
      expect(const SiloDownloadQuality('5mbps').label, '5 Mbps');
      expect(const SiloDownloadQuality('5mbps').effectiveBitrateKbps, 5000);
    });

    test('offers original only when converting is off for the server or the user', () {
      expect(SiloDownloadCapability.fromJson(_capability(transcode: false)).allowedQualities.map((q) => q.preset), [
        'original',
      ]);
      final userRefused = SiloDownloadCapability.fromJson({..._capability(), 'transcode_user_allowed': false});
      expect(userRefused.allowedQualities.single.isOriginal, isTrue);
      expect(userRefused.effectivePreset('10mbps'), 'original');
      expect(SiloDownloadCapability.fromJson(_capability()).effectivePreset('10mbps'), '10mbps');
      expect(SiloDownloadCapability.fromJson(_capability()).effectivePreset('3mbps'), 'original');
    });

    test('an empty preset list still offers original; a disabled or older registry is not managed', () {
      final empty = SiloDownloadCapability.fromJson({..._capability(), 'quality_presets': <String>[]});
      expect(empty.allowedQualities.single.isOriginal, isTrue);
      expect(SiloDownloadCapability.fromJson(_capability(enabled: false)).managesDownloads, isFalse);
      expect(SiloDownloadCapability.fromJson(_capability(bounded: false)).managesDownloads, isFalse);
      expect(SiloDownloadCapability.fromJson({..._capability(), 'allowed': false}).managesDownloads, isFalse);
    });

    test('the client offers no choice without the registry or with original only', () async {
      server.capabilityRoute = false;
      expect(await client.downloadQualityChoices(), isEmpty);
      managed.resetForTesting(persistence: persistence);
      server.capabilityRoute = true;
      server.capability = _capability(transcode: false);
      expect(await client.downloadQualityChoices(), isEmpty);
      managed.resetForTesting(persistence: persistence);
      server.capability = _capability();
      expect((await client.downloadQualityChoices()).length, 6);
    });
  });

  group('registration', () {
    test('a server without the registry keeps the untracked direct download', () async {
      server.capabilityRoute = false;
      final resolution = await client.resolveDownload(movie);
      expect(resolution.videoUrl, 'https://silo.example.com/api/v2/direct-download?file_id=42&dl=link#container=mkv');
      expect(resolution.headers, isEmpty);
      expect(server.calls('POST', '/api/v2/downloads'), isEmpty);
      expect(server.calls('GET', '/api/v2/downloads'), isEmpty);
      expect(await managed.recordFor(_movieKey), isNull);
    });

    test('an original download is registered, then fetched through the direct link', () async {
      final resolution = await client.resolveDownload(movie);

      final create = server.calls('POST', '/api/v2/downloads').single;
      expect(jsonDecode(create.body), {
        'content_id': 'movie:m1',
        'media_file_id': '42',
        'quality': 'original',
        'expected_revision': 0,
      });
      expect(create.headers['X-Silo-Device-Id'], 'dev-1');
      expect(create.headers['X-Profile-Id'], 'p-owner');
      // The registry is read before creating (never a blind POST).
      expect(
        server.requests.indexOf(server.calls('GET', '/api/v2/downloads').first),
        lessThan(server.requests.indexOf(create)),
      );

      expect(resolution.videoUrl, 'https://silo.example.com/api/v2/direct-download?file_id=42&dl=link#container=mkv');
      expect(resolution.headers, isEmpty, reason: 'no credential rides with an original download');

      final patch = server.calls('PATCH', '/api/v2/downloads/dl-1').single;
      final body = jsonDecode(patch.body) as Map<String, dynamic>;
      expect(body['status'], 'downloading');
      expect(body['revision'], 1);
      expect(DateTime.tryParse(body['updated_at'] as String), isNotNull);

      final record = (await managed.recordFor(_movieKey))!;
      expect(record.entryId, 'dl-1');
      expect(record.pendingStatus, isNull);
    });

    test('an episode names its series and itself', () async {
      final episode = MediaItem.silo(
        id: 'ep:e1',
        kind: MediaKind.episode,
        serverId: 'srv-1',
        grandparentId: 'series:s1',
      );
      await client.resolveDownload(episode);
      expect(jsonDecode(server.calls('POST', '/api/v2/downloads').single.body), {
        'content_id': 'series:s1',
        'episode_id': 'ep:e1',
        'media_file_id': '42',
        'quality': 'original',
        'expected_revision': 0,
      });
    });

    test('an existing entry for the same file and quality is reused', () async {
      server.entries.add(_entry(status: 'downloading', revision: 3));
      await client.resolveDownload(movie);
      expect(server.calls('POST', '/api/v2/downloads'), isEmpty);
      expect((await managed.recordFor(_movieKey))!.revision, 3);
      expect(jsonDecode(server.calls('PATCH', '/api/v2/downloads/dl-1').single.body)['revision'], 3);
    });

    test('another quality replaces the existing entry under its revision guard', () async {
      server.entries.add(_entry(revision: 2));
      server.onCreate = (body) => _entry(quality: '5mbps', status: 'ready', format: 'transcode', revision: 3);
      await client.setDownloadQuality('movie:m1', '5mbps');
      await client.resolveDownload(movie);
      expect(jsonDecode(server.calls('POST', '/api/v2/downloads').single.body), {
        'content_id': 'movie:m1',
        'media_file_id': '42',
        'quality': '5mbps',
        'expected_revision': 2,
        'expected_download_id': 'dl-1',
      });
    });

    test('a prepared quality waits while the server prepares, then downloads its file with headers', () async {
      server.onCreate = (body) => _entry(
        quality: body['quality'] as String,
        status: 'preparing',
        format: 'transcode',
        preparation: {'state': 'queued', 'queue_position': 2},
      );
      await client.setDownloadQuality('movie:m1', '10mbps');

      await expectLater(
        client.resolveDownload(movie),
        throwsA(isA<DownloadNotReadyException>().having((e) => e.message, 'message', contains('number 2 in line'))),
      );
      expect(jsonDecode(server.calls('POST', '/api/v2/downloads').single.body)['quality'], '10mbps');
      expect(server.calls('PATCH', '/api/v2/downloads/dl-1'), isEmpty, reason: 'nothing is downloading yet');

      server.entries.single
        ..['status'] = 'ready'
        ..remove('preparation');
      final resolution = await client.resolveDownload(movie);
      expect(server.calls('POST', '/api/v2/downloads'), hasLength(1), reason: 'the ready entry is reused');
      expect(resolution.videoUrl, 'https://silo.example.com/base/api/v2/downloads/dl-1/file#container=mp4');
      expect(resolution.headers['Authorization'], 'Bearer acc-1');
      expect(resolution.headers['X-Profile-Id'], 'p-owner');
      expect(resolution.headers['X-Silo-Device-Id'], 'dev-1');
      expect(resolution.videoUrl, isNot(contains('acc-1')));
    });

    test('a quality chosen for a show applies to its episodes; original on an episode overrides it', () async {
      await client.setDownloadQuality('series:s1', '2mbps');
      expect(await managed.qualityFor(_scope, ['ep:e1', 'season:1', 'series:s1']), '2mbps');
      await client.setDownloadQuality('ep:e1', 'original');
      expect(await managed.qualityFor(_scope, ['ep:e1', 'season:1', 'series:s1']), 'original');
    });

    test('a quality the account may no longer request falls back to original', () async {
      await client.setDownloadQuality('movie:m1', '10mbps');
      server.capability = _capability(transcode: false);
      await client.resolveDownload(movie);
      expect(jsonDecode(server.calls('POST', '/api/v2/downloads').single.body)['quality'], 'original');
    });

    test('a refused creation names the reason', () async {
      server.createStatus = 429;
      await expectLater(
        client.resolveDownload(movie),
        throwsA(
          isA<MediaServerHttpException>()
              .having((e) => e.statusCode, 'status', 429)
              .having((e) => e.display, 'display', contains('download limit')),
        ),
      );
    });

    test('a failed preparation is reported, and a retry replaces the failed entry', () async {
      server.entries.add(_entry(status: 'failed', quality: '10mbps', format: 'transcode'));
      server.onCreate = (body) => _entry(quality: '10mbps', status: 'failed', format: 'transcode', revision: 2);
      await client.setDownloadQuality('movie:m1', '10mbps');
      await expectLater(
        client.resolveDownload(movie),
        throwsA(isA<MediaServerHttpException>().having((e) => e.display, 'display', contains('could not prepare'))),
      );
      expect(jsonDecode(server.calls('POST', '/api/v2/downloads').single.body)['expected_revision'], 1);
    });
  });

  group('local life of the copy', () {
    test('completion reports completed with the entry revision', () async {
      await client.resolveDownload(movie);
      await managed.localCopyCompleted(_movieKey);
      final bodies = [for (final r in server.calls('PATCH', '/api/v2/downloads/dl-1')) jsonDecode(r.body)];
      expect(bodies.map((b) => b['status']), ['downloading', 'completed']);
      expect(bodies.last['revision'], 1);
      expect((await managed.recordFor(_movieKey))!.pendingStatus, isNull);
    });

    test('resolving a completed copy again (subtitle follow-up) registers and reports nothing', () async {
      await client.resolveDownload(movie);
      await managed.localCopyCompleted(_movieKey);
      server.requests.clear();
      final resolution = await client.resolveDownload(movie);
      expect(resolution.videoUrl, contains('/direct-download?'));
      expect(server.calls('GET', '/api/v2/downloads'), isEmpty);
      expect(server.calls('POST', '/api/v2/downloads'), isEmpty);
      expect(server.requests.where((r) => r.method == 'PATCH'), isEmpty);
    });

    test('a completion the server did not receive is sent again with the same time', () async {
      await client.resolveDownload(movie);
      client.setOfflineMode(true);
      await managed.localCopyCompleted(_movieKey);
      expect(server.calls('PATCH', '/api/v2/downloads/dl-1'), hasLength(1));
      final pending = (await managed.recordFor(_movieKey))!;
      expect(pending.pendingStatus, 'completed');
      final at = pending.pendingAt!;

      client.setOfflineMode(false);
      await managed.sync(_scope);
      final last = jsonDecode(server.calls('PATCH', '/api/v2/downloads/dl-1').last.body) as Map<String, dynamic>;
      expect(last['status'], 'completed');
      expect(DateTime.parse(last['updated_at'] as String), at.toUtc());
    });

    test('deleting the local copy deletes the entry', () async {
      await client.resolveDownload(movie);
      await managed.localCopyRemoved(_movieKey);
      expect(server.calls('DELETE', '/api/v2/downloads/dl-1'), hasLength(1));
      expect(server.entries, isEmpty);
      expect(await managed.recordFor(_movieKey), isNull);
      expect(await managed.tombstonesForTesting(), isEmpty);
    });

    test('a deletion the server could not take is kept and sent at the next sync', () async {
      await client.resolveDownload(movie);
      server.failDeletes = true;
      await managed.localCopyRemoved(_movieKey);
      expect(await managed.tombstonesForTesting(), ['dl-1']);

      server.failDeletes = false;
      await managed.sync(_scope);
      expect(await managed.tombstonesForTesting(), isEmpty);
      expect(server.entries, isEmpty);
    });

    test('the records survive a restart (persisted)', () async {
      await client.resolveDownload(movie);
      expect(persistence.value, contains('dl-1'));
      expect(persistence.value, isNot(contains('acc-1')), reason: 'no credential is stored');
      final reloaded = SiloManagedDownloads(persistence: persistence);
      expect((await reloaded.recordFor(_movieKey))!.entryId, 'dl-1');
    });

    test('a download that is not registered reports nothing', () async {
      await managed.localCopyCompleted('srv-1:movie:other');
      await managed.localCopyRemoved('srv-1:movie:other');
      expect(server.requests, isEmpty);
    });
  });

  group('revocation', () {
    test('a revoked entry removes the local copy, then the entry', () async {
      await client.resolveDownload(movie);
      server.entries.single['status'] = 'revoked';
      await managed.sync(_scope);
      expect(revoked, [_movieKey]);
      expect(server.calls('DELETE', '/api/v2/downloads/dl-1'), hasLength(1));
      expect(await managed.recordFor(_movieKey), isNull);
    });

    test('a revoked entry this device holds nothing for is only confirmed', () async {
      server.entries.add(_entry(id: 'dl-old', status: 'revoked', fileId: '7', contentId: 'movie:other'));
      await managed.sync(_scope);
      expect(revoked, isEmpty);
      expect(server.calls('DELETE', '/api/v2/downloads/dl-old'), hasLength(1));
    });

    test('without revoked_removes_local the copy stays', () async {
      await client.resolveDownload(movie);
      server.capability = _capability(revokedRemovesLocal: false);
      server.entries.single['status'] = 'revoked';
      await managed.sync(_scope);
      expect(revoked, isEmpty);
      expect(server.calls('DELETE', '/api/v2/downloads/dl-1'), isEmpty);
      expect(await managed.recordFor(_movieKey), isNotNull);
    });

    test('retrying a revoked download fails with the reason and removes the copy', () async {
      await client.resolveDownload(movie);
      server.entries.single['status'] = 'revoked';
      await expectLater(
        client.resolveDownload(movie),
        throwsA(isA<MediaServerHttpException>().having((e) => e.display, 'display', contains('administrator'))),
      );
      expect(server.calls('POST', '/api/v2/downloads'), hasLength(1), reason: 'no new registration');
      await pumpEventQueue();
      expect(revoked, [_movieKey]);
    });

    test('a finished copy whose entry the server no longer lists is forgotten; the file stays', () async {
      await client.resolveDownload(movie);
      await managed.localCopyCompleted(_movieKey);
      server.entries.clear();
      await managed.sync(_scope);
      expect(revoked, isEmpty);
      expect(await managed.recordFor(_movieKey), isNull);
    });
  });

  test('the request bodies match the server contract', () {
    expect(
      SiloDownloadRegistryApi.statusBody(
        status: 'completed',
        updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        revision: 4,
      ),
      {'status': 'completed', 'updated_at': '2026-01-02T03:04:05.000Z', 'revision': 4},
    );
    expect(
      SiloDownloadRegistryApi.createBody(
        contentId: 'series:s1',
        episodeId: 'ep:e1',
        mediaFileId: '42',
        quality: '1mbps',
        expected: SiloDownloadEntry.fromJson(_entry(revision: 5)),
      ),
      {
        'content_id': 'series:s1',
        'episode_id': 'ep:e1',
        'media_file_id': '42',
        'quality': '1mbps',
        'expected_revision': 5,
        'expected_download_id': 'dl-1',
      },
    );
  });

  test('download trackers are told about completion and removal, and never throw', () async {
    final tracker = _RecordingTracker();
    DownloadServerTrackers.register(tracker);
    addTearDown(() => DownloadServerTrackers.unregister(tracker));
    DownloadServerTrackers.notifyCompleted('a');
    DownloadServerTrackers.notifyRemoved('b');
    await pumpEventQueue();
    expect(tracker.events, ['completed a', 'removed b']);
  });
}

class _RecordingTracker implements DownloadServerTracker {
  final events = <String>[];

  @override
  Future<void> localCopyCompleted(String globalKey) async {
    events.add('completed $globalKey');
    throw StateError('ignored');
  }

  @override
  Future<void> localCopyRemoved(String globalKey) async => events.add('removed $globalKey');
}
