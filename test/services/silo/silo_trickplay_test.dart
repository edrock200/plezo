import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/scrub_preview_source.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_trickplay.dart';

const _origin = 'https://silo.example.com';
String _resolve(String url) => url.startsWith('/') ? '$_origin$url' : url;

/// Silo Android's `get_watch_trickplay_ok.json` fixture: 1020 thumbnails of
/// 300x126 on 10x10 sheets, so 11 sheets.
Map<String, dynamic> _fixture({
  String fileId = '42',
  int columns = 10,
  int rows = 10,
  int count = 1020,
  int? sheets,
  String expiresAt = '2026-01-03T03:04:05.000Z',
  String sig = 'a',
}) {
  final perSheet = columns * rows;
  final sheetCount = sheets ?? (count + perSheet - 1) ~/ perSheet;
  return {
    'file_id': fileId,
    'interval_ms': 10000,
    'thumbnail_width': 300,
    'thumbnail_height': 126,
    'tile_columns': columns,
    'tile_rows': rows,
    'thumbnail_count': count,
    'sheets': [
      for (var i = 0; i < sheetCount; i++)
        {'index': i, 'url': '/api/v2/artwork/trickplay/42/9913/$i.9913.jpg?exp=1767409445&sig=$sig$i'},
    ],
    'expires_at': expiresAt,
  };
}

SiloTrickplayManifest _parse(Map<String, dynamic> json, {String fileId = '42'}) =>
    SiloTrickplayManifest.parse(json, expectedFileId: fileId, resolveUrl: _resolve)!;

void main() {
  group('SiloTrickplayManifest.parse', () {
    test('reads the fixture and resolves sheet URLs against the origin, query untouched', () {
      final m = _parse(_fixture());
      expect(m.intervalMs, 10000);
      expect(m.columns, 10);
      expect(m.rows, 10);
      expect(m.count, 1020);
      expect(m.sheetUrls, hasLength(11));
      expect(m.sheetUrls.first, '$_origin/api/v2/artwork/trickplay/42/9913/0.9913.jpg?exp=1767409445&sig=a0');
      expect(m.expiresAt, DateTime.utc(2026, 1, 3, 3, 4, 5));
      expect(m.toString(), isNot(contains('sig=')));
    });

    test('keeps absolute presigned URLs and accepts a numeric file id and unordered sheets', () {
      final json = _fixture(count: 150)
        ..['file_id'] = 42
        ..['sheets'] = [
          {'index': 1, 'url': 'https://bucket.example.net/1.jpg?X-Amz-Signature=b'},
          {'index': 0, 'url': 'https://bucket.example.net/0.jpg?X-Amz-Signature=a'},
        ];
      final m = _parse(json);
      expect(m.sheetUrls, [
        'https://bucket.example.net/0.jpg?X-Amz-Signature=a',
        'https://bucket.example.net/1.jpg?X-Amz-Signature=b',
      ]);
    });

    test('an unparsable expiry keeps the manifest without one', () {
      expect(_parse(_fixture(expiresAt: 'soon')).expiresAt, isNull);
    });

    final rejects = <String, Map<String, dynamic> Function()>{
      'another file': () => _fixture(fileId: '43'),
      'zero interval': () => _fixture()..['interval_ms'] = 0,
      'zero count': () => _fixture(count: 0, sheets: 0),
      'fractional size': () => _fixture()..['thumbnail_width'] = 300.5,
      'size over 8192': () => _fixture()..['thumbnail_height'] = 9000,
      'sheet wider than 8192': () => _fixture(columns: 30, count: 300),
      'a missing sheet': () => _fixture(sheets: 10),
      'an extra sheet': () => _fixture(sheets: 12),
      'a duplicate index': () => _fixture()..['sheets'][1]['index'] = 0,
      'a non-http URL': () => _fixture()..['sheets'][0]['url'] = 'file:///etc/passwd',
      'a missing URL': () => _fixture()..['sheets'][0].remove('url'),
      'no sheets list': () => _fixture()..remove('sheets'),
    };
    rejects.forEach((name, json) {
      test('refuses $name', () {
        expect(SiloTrickplayManifest.parse(json(), expectedFileId: '42', resolveUrl: _resolve), isNull);
      });
    });
    test('refuses a non-object answer', () {
      expect(SiloTrickplayManifest.parse([1], expectedFileId: '42', resolveUrl: _resolve), isNull);
    });
  });

  group('tileAt', () {
    final m = _parse(_fixture());
    test('maps time to sheet, column and row', () {
      expect(m.tileAt(Duration.zero), const SiloTrickplayTile(sheet: 0, column: 0, row: 0));
      expect(m.tileAt(const Duration(milliseconds: 9999)), const SiloTrickplayTile(sheet: 0, column: 0, row: 0));
      expect(m.tileAt(const Duration(seconds: 10)), const SiloTrickplayTile(sheet: 0, column: 1, row: 0));
      // Thumbnail 123: sheet 1, cell 23 → column 3, row 2.
      expect(m.tileAt(const Duration(seconds: 1230)), const SiloTrickplayTile(sheet: 1, column: 3, row: 2));
      // Last thumbnail (1019): sheet 10, cell 19.
      expect(m.tileAt(const Duration(seconds: 10190)), const SiloTrickplayTile(sheet: 10, column: 9, row: 1));
    });
    test('a time past the end shows the last thumbnail; a negative time none', () {
      expect(m.tileAt(const Duration(hours: 10)), const SiloTrickplayTile(sheet: 10, column: 9, row: 1));
      expect(m.tileAt(const Duration(milliseconds: -1)), isNull);
    });
  });

  group('SiloTrickplayService', () {
    late DateTime now;
    late List<String> sheetRequests;
    late Map<String, SiloTrickplaySheetResult Function()> sheetAnswers;
    late List<Object> manifestAnswers;
    late int manifestReads;

    setUp(() {
      now = DateTime.utc(2026, 1, 3, 2);
      sheetRequests = [];
      sheetAnswers = {};
      manifestAnswers = [];
      manifestReads = 0;
    });

    SiloTrickplayService service({SiloTrickplayManifest? manifest, int cacheBytes = 1 << 20}) => SiloTrickplayService(
      manifest: manifest ?? _parse(_fixture()),
      now: () => now,
      sheetCacheBytes: cacheBytes,
      loadManifest: () async {
        manifestReads++;
        final answer = manifestAnswers.removeAt(0);
        if (answer is SiloTrickplayManifest) return answer;
        throw answer;
      },
      loadSheet: (url) async {
        sheetRequests.add(url);
        final answer = sheetAnswers[url];
        return answer != null ? answer() : SiloTrickplaySheetLoaded(Uint8List.fromList(utf8.encode(url)));
      },
    );

    test('getFrame describes the tile on its sheet', () {
      final s = service();
      final frame = s.getFrame(const Duration(seconds: 1230));
      expect(frame, isA<SheetScrubFrame>());
      frame as SheetScrubFrame;
      expect((frame.tileColumn, frame.tileRow, frame.sheetColumns, frame.sheetRows), (3, 2, 10, 10));
      expect(frame.aspectRatio, closeTo(300 / 126, 1e-9));
      // The same sheet keeps the same image provider.
      expect((s.getFrame(const Duration(seconds: 1240)) as SheetScrubFrame).sheet, same(frame.sheet));
    });

    test('loads a sheet once, shares the download and prefetches the next one', () async {
      final s = service();
      s.getFrame(const Duration(seconds: 5));
      final a = s.sheetBytes(0);
      final b = s.sheetBytes(0);
      await Future.wait([a, b]);
      await s.sheetBytes(0);
      expect(sheetRequests.where((u) => u.contains('/0.9913')), hasLength(1));
      expect(sheetRequests.where((u) => u.contains('/1.9913')), hasLength(1));
    });

    test('bounds the held sheets, dropping the least recently used', () async {
      final s = service(cacheBytes: 250);
      for (final i in [0, 1, 2]) {
        await s.sheetBytes(i);
      }
      // Each fake sheet is ~90 bytes, so two fit.
      expect(s.heldSheets, [1, 2]);
      expect(s.heldBytes, lessThanOrEqualTo(250));
    });

    test('a refused sheet renews the URLs once and retries with the fresh one', () async {
      final s = service();
      final stale = s.manifest.sheetUrls[0];
      sheetAnswers[stale] = () => const SiloTrickplaySheetRefused();
      final fresh = _parse(_fixture(sig: 'z'));
      manifestAnswers.add(fresh);
      final bytes = await s.sheetBytes(0);
      expect(bytes, isNotNull);
      expect(manifestReads, 1);
      expect(sheetRequests, [stale, fresh.sheetUrls[0]]);
    });

    test('a failed sheet backs off, then is asked for again', () async {
      final s = service();
      final url = s.manifest.sheetUrls[0];
      sheetAnswers[url] = () => const SiloTrickplaySheetFailed();
      expect(await s.sheetBytes(0), isNull);
      expect(s.getFrame(Duration.zero), isNull, reason: 'time-only while backing off');
      expect(await s.sheetBytes(0), isNull);
      expect(sheetRequests, hasLength(1));
      now = now.add(SiloTrickplayService.retryBackoff);
      sheetAnswers.remove(url);
      expect(await s.sheetBytes(0), isNotNull);
      expect(s.getFrame(Duration.zero), isNotNull);
    });

    test('renews before expiry; the same layout keeps held sheets', () async {
      final s = service();
      await s.sheetBytes(0);
      now = DateTime.utc(2026, 1, 3, 3, 3, 30); // 35 s before expiry
      manifestAnswers.add(_parse(_fixture(sig: 'n', expiresAt: '2026-01-03T04:00:00Z')));
      final before = s.getFrame(Duration.zero) as SheetScrubFrame;
      await pumpEventQueue();
      expect(manifestReads, 1);
      expect(s.manifest.sheetUrls[0], contains('sig=n0'));
      expect(s.heldSheets, contains(0));
      expect((s.getFrame(Duration.zero) as SheetScrubFrame).sheet, same(before.sheet));
    });

    test('a renewal that lays the thumbnails out again drops held sheets', () async {
      final s = service();
      await s.sheetBytes(0);
      now = DateTime.utc(2026, 1, 3, 3, 4);
      manifestAnswers.add(_parse(_fixture(columns: 5, expiresAt: '2026-01-03T04:00:00Z')));
      final before = s.getFrame(Duration.zero) as SheetScrubFrame;
      await pumpEventQueue();
      expect(s.heldSheets, isEmpty);
      final after = s.getFrame(Duration.zero) as SheetScrubFrame;
      expect(after.sheetColumns, 5);
      expect(after.sheet, isNot(same(before.sheet)));
    });

    test('a refused renewal withdraws the previews; a transient one keeps them', () async {
      final s = service();
      now = DateTime.utc(2026, 1, 3, 3, 4);
      manifestAnswers.add(MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'offline'));
      s.getFrame(Duration.zero);
      await pumpEventQueue();
      expect(s.isAvailable, isTrue);
      now = now.add(SiloTrickplayService.retryBackoff);
      manifestAnswers.add(MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 404));
      s.getFrame(Duration.zero);
      await pumpEventQueue();
      expect(manifestReads, 2);
      expect(s.isAvailable, isFalse);
      expect(s.getFrame(Duration.zero), isNull);
    });

    test('transient classification', () {
      bool t(Object e) => SiloTrickplayService.isTransientTrickplayError(e);
      expect(t(MediaServerHttpException(type: MediaServerHttpErrorType.connectionTimeout)), isTrue);
      expect(t(MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 503)), isTrue);
      expect(t(MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 429)), isTrue);
      expect(t(MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 403)), isFalse);
      expect(t(const SiloTrickplayUnusable()), isFalse);
    });

    test('dispose makes it unavailable', () {
      final s = service()..dispose();
      expect(s.isAvailable, isFalse);
      expect(s.getFrame(Duration.zero), isNull);
    });
  });

  group('fetchSheet', () {
    test('sends no credentials or device headers and caps the body', () async {
      late http.BaseRequest seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response.bytes(List.filled(10, 1), 200);
      });
      final ok = await SiloTrickplayService.fetchSheet(client, 'https://cdn.example.net/0.jpg?sig=a');
      expect(ok, isA<SiloTrickplaySheetLoaded>());
      expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
      expect(seen.headers.keys.where((k) => k.toLowerCase().startsWith('x-')), isEmpty);
      expect(
        await SiloTrickplayService.fetchSheet(client, 'https://cdn.example.net/0.jpg', maxBytes: 5),
        isA<SiloTrickplaySheetFailed>(),
      );
    });

    test('403/404 are refused URLs; 500 is a failure', () async {
      for (final (status, type) in [
        (403, SiloTrickplaySheetRefused),
        (404, SiloTrickplaySheetRefused),
        (500, SiloTrickplaySheetFailed),
      ]) {
        final client = MockClient((_) async => http.Response('', status));
        final result = await SiloTrickplayService.fetchSheet(client, 'https://cdn.example.net/0.jpg');
        expect(result.runtimeType, type);
      }
    });
  });

  group('SiloClient.createScrubPreviewSource', () {
    late List<http.Request> requests;

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
    });

    SiloClient client({required bool available, http.Response? manifest}) => SiloClient.forTesting(
      SiloConnection(
        id: 'srv-1/1/p-owner',
        baseUrl: '$_origin/base',
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
      ),
      headers: const SiloDeviceHeaders(
        deviceId: 'dev-1',
        deviceName: 'Test',
        platform: 'linux',
        clientFamily: 'desktop',
        clientVersion: '1.0',
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/watch/movie:m1')) {
          return http.Response(
            jsonEncode({
              'versions': [
                {'file_id': '41', 'trickplay_available': true},
                {'file_id': '42', 'trickplay_available': available},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/watch/movie:m1/trickplay')) {
          return manifest ?? http.Response(jsonEncode(_fixture()), 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('', 404);
      }),
    );

    final item = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
    final source = MediaSourceInfo(
      videoUrl: '',
      audioTracks: [],
      subtitleTracks: [],
      chapters: [],
      mediaSourceId: '42',
    );

    test('reads the manifest of the streamed file when its version has previews', () async {
      final c = client(available: true);
      expect(c.capabilities.scrubThumbnails, isTrue);
      final preview = await c.createScrubPreviewSource(item: item, mediaSource: source);
      expect(preview, isA<SiloTrickplayService>());
      expect(preview!.isAvailable, isTrue);
      final read = requests.singleWhere((r) => r.url.path.endsWith('/trickplay'));
      expect(read.url.queryParameters['file_id'], '42');
      expect(read.headers['Authorization'], 'Bearer acc-1');
      expect((preview as SiloTrickplayService).manifest.sheetUrls.first, startsWith('$_origin/api/v2/artwork/'));
    });

    test('no previews when the version lacks trickplay_available', () async {
      final c = client(available: false);
      expect(await c.createScrubPreviewSource(item: item, mediaSource: source), isNull);
      expect(requests.where((r) => r.url.path.endsWith('/trickplay')), isEmpty);
    });

    test('a 404, a refusal or an unusable manifest keeps the time-only preview', () async {
      for (final answer in [
        http.Response('{}', 404, headers: {'content-type': 'application/json'}),
        http.Response('{}', 403, headers: {'content-type': 'application/json'}),
        http.Response(jsonEncode(_fixture(fileId: '41')), 200, headers: {'content-type': 'application/json'}),
      ]) {
        final c = client(available: true, manifest: answer);
        expect(await c.createScrubPreviewSource(item: item, mediaSource: source), isNull);
      }
    });
  });
}
