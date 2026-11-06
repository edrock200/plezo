import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_requests.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection() => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com',
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

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response _problem(int status, String code, {String? detail}) => http.Response(
  jsonEncode({
    'type': 'https://siloserver.org/docs/api/v2/problems/$code',
    'title': code,
    'status': status,
    'detail': ?detail,
  }),
  status,
  headers: {'content-type': 'application/problem+json'},
);

Map<String, dynamic> _result(int id, {String type = 'movie', String availability = 'missing', Map? request}) => {
  'media_type': type,
  'tmdb_id': id,
  'title': 'Title $id',
  'year': 2020,
  'availability': availability,
  'request': request ?? {'requestable': true, 'following': false, 'requested_by_viewer': false},
};

Map<String, dynamic> _record(
  String id, {
  String status = 'pending',
  String outcome = 'active',
  String? state,
  String created = '2026-01-02T03:04:05.000Z',
}) => {
  'id': id,
  'provider': 'tmdb',
  'media_type': 'movie',
  'tmdb_id': 949,
  'title': 'Heat',
  'status': status,
  'outcome': outcome,
  'state': ?state,
  'targets': [],
  'created_at': created,
  'updated_at': created,
};

void main() {
  late List<http.Request> requests;

  setUp(() => requests = []);

  SiloClient client(FutureOr<http.Response> Function(http.Request request) handler) => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      requests.add(request);
      return handler(request);
    }),
  );

  group('status gate', () {
    test('available only when enabled, allowed and state available', () {
      expect(
        SiloRequestsStatus.fromJson({'requests_enabled': true, 'allowed': true, 'state': 'available'}).isAvailable,
        isTrue,
      );
      expect(
        SiloRequestsStatus.fromJson({'requests_enabled': true, 'allowed': false, 'state': 'available'}).isAvailable,
        isFalse,
      );
      expect(SiloRequestsStatus.fromJson({'requests_enabled': true, 'state': 'available'}).isAvailable, isFalse);
      expect(
        SiloRequestsStatus.fromJson({'requests_enabled': false, 'allowed': true, 'state': 'disabled'}).isAvailable,
        isFalse,
      );
      expect(
        SiloRequestsStatus.fromJson({'requests_enabled': true, 'allowed': true, 'state': 'not_configured'}).isAvailable,
        isFalse,
      );
    });

    test('starts closed, opens on an enabled answer and keeps it through a failure', () async {
      var fail = false;
      final c = client((request) {
        expect(request.url.path, '/api/v2/requests/status');
        expect(request.headers['X-Profile-Id'], 'p-owner');
        if (fail) return http.Response('oops', 500);
        return _json({'requests_enabled': true, 'allowed': true, 'state': 'available', 'follow_supported': true});
      });
      expect(c.requests.enabled.value, isFalse);
      expect(c.requests.resolved, isFalse);
      expect(await c.requests.refreshStatus(), isTrue);
      expect(c.requests.enabled.value, isTrue);
      expect(c.requests.resolved, isTrue);

      fail = true;
      expect(await c.requests.refreshStatus(force: true), isTrue, reason: 'a failed read keeps the previous answer');
      expect(requests, hasLength(2));
    });

    test('a disabled answer closes an open gate; fresh answers are not re-read', () async {
      var enabled = true;
      final c = client(
        (_) => _json({'requests_enabled': enabled, 'allowed': enabled, 'state': enabled ? 'available' : 'disabled'}),
      );
      await c.requests.refreshStatus();
      expect(c.requests.enabled.value, isTrue);
      enabled = false;
      await c.requests.refreshStatus();
      expect(requests, hasLength(1), reason: 'the answer is still fresh');
      await c.requests.refreshStatus(force: true);
      expect(c.requests.enabled.value, isFalse);
    });

    test('concurrent reads share one request', () async {
      final gate = Completer<void>();
      final c = client((_) async {
        await gate.future;
        return _json({'requests_enabled': true, 'allowed': true, 'state': 'available'});
      });
      final a = c.requests.refreshStatus();
      final b = c.requests.refreshStatus();
      gate.complete();
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(requests, hasLength(1));
    });

    test('each client has its own gate', () {
      final a = client((_) => _json({}));
      final b = client((_) => _json({}));
      expect(identical(a.requests, a.requests), isTrue);
      expect(identical(a.requests, b.requests), isFalse);
    });
  });

  group('search', () {
    test('sends q, media_type and page and drops unsupported media types', () async {
      final c = client(
        (_) => _json({
          'page': 1,
          'total_pages': 1,
          'total_results': 3,
          'results': [
            _result(1),
            _result(2, type: 'series'),
            {..._result(3), 'media_type': 'audiobook'},
            {'media_type': 'movie', 'title': 'no id'},
          ],
        }),
      );
      final results = await c.requests.search('heat');
      expect(requests.single.url.path, '/api/v2/requests/search');
      expect(requests.single.url.queryParameters, {'q': 'heat', 'media_type': 'all', 'page': '1'});
      expect(results.map((r) => r.key), ['movie:1', 'series:2']);
    });

    test('"Available to request" leaves out titles the server marks available (#773)', () {
      final results = [
        SiloRequestMediaResult.fromJson(_result(1))!,
        SiloRequestMediaResult.fromJson(
          _result(2, availability: 'available', request: {'requestable': false, 'reason': 'already_available'}),
        )!,
        SiloRequestMediaResult.fromJson(
          _result(
            3,
            request: {'requestable': false, 'status': 'pending', 'state': 'pending', 'reason': 'already_requested'},
          ),
        )!,
      ];
      expect(siloRequestsWithoutLibraryTitles(results).map((r) => r.tmdbId), [1, 3]);
      expect(siloRequestsWithoutLibraryTitles(results.take(2).skip(1)), isEmpty);
    });
  });

  group('display state', () {
    test('annotations', () {
      expect(SiloRequestDisplay.ofAnnotation('missing', const SiloRequestState(requestable: true)), isNull);
      expect(
        SiloRequestDisplay.ofAnnotation('available', const SiloRequestState())!.kind,
        SiloRequestDisplayKind.inLibrary,
      );
      expect(
        SiloRequestDisplay.ofAnnotation('missing', const SiloRequestState(status: 'pending', state: 'pending'))!.kind,
        SiloRequestDisplayKind.pending,
      );
      expect(
        SiloRequestDisplay.ofAnnotation('missing', const SiloRequestState(status: 'downloading'))!.kind,
        SiloRequestDisplayKind.onTheWay,
      );
      // A partly available series with an active request is on its way, not in the library.
      expect(
        SiloRequestDisplay.ofAnnotation('available', const SiloRequestState(state: 'processing'))!.kind,
        SiloRequestDisplayKind.onTheWay,
      );
      expect(
        SiloRequestDisplay.ofAnnotation('missing', const SiloRequestState(reason: 'quota_exceeded')),
        const SiloRequestDisplay(SiloRequestDisplayKind.unavailable, reason: 'quota_exceeded'),
      );
    });

    test('records', () {
      SiloRequestDisplay of(Map<String, dynamic> json) => SiloMediaRequest.fromJson(json)!.display;
      expect(of(_record('1')).kind, SiloRequestDisplayKind.pending);
      expect(of(_record('1', status: 'queued', state: 'approved')).kind, SiloRequestDisplayKind.onTheWay);
      expect(of(_record('1', status: 'completed', state: 'processing')).kind, SiloRequestDisplayKind.onTheWay);
      expect(of(_record('1', status: 'completed', state: 'available')).kind, SiloRequestDisplayKind.inLibrary);
      expect(of(_record('1', status: 'completed')).kind, SiloRequestDisplayKind.inLibrary, reason: 'older server');
      final declined = of({..._record('1', outcome: 'declined', state: 'declined'), 'outcome_reason': 'Not now'});
      expect(declined.kind, SiloRequestDisplayKind.attention);
      expect(declined.attention, SiloRequestAttention.declined);
      expect(declined.reason, 'Not now');
      expect(of(_record('1', outcome: 'failed')).attention, SiloRequestAttention.failed);
      expect(of(_record('1', outcome: 'cancelled', state: 'cancelled')).kind, SiloRequestDisplayKind.unavailable);
    });

    test('in library opens the library item, everything else the request', () {
      const inLibrary = SiloRequestDisplay(SiloRequestDisplayKind.inLibrary);
      expect(inLibrary.libraryItemToOpen('movie:heat-1995'), 'movie:heat-1995');
      expect(inLibrary.libraryItemToOpen(null), isNull);
      expect(const SiloRequestDisplay(SiloRequestDisplayKind.onTheWay).libraryItemToOpen('movie:heat-1995'), isNull);
    });

    test('My requests: in motion, needs attention, landed; newest first; cancelled dropped', () {
      final records = [
        for (final json in [
          _record('old-pending', created: '2026-01-01T00:00:00Z'),
          _record('landed', status: 'completed', state: 'available', created: '2026-03-01T00:00:00Z'),
          _record('cancelled', outcome: 'cancelled', state: 'cancelled', created: '2026-04-01T00:00:00Z'),
          _record('failed', outcome: 'failed', state: 'failed', created: '2026-02-01T00:00:00Z'),
          _record('new-pending', created: '2026-01-05T00:00:00.5Z'),
          {..._record('book'), 'media_type': 'audiobook'},
        ])
          SiloMediaRequest.fromJson(json)!,
      ];
      expect(siloBucketMyRequests(records).map((r) => r.id), ['new-pending', 'old-pending', 'failed', 'landed']);
    });

    test('current record: the newest active, else the newest unless cancelled', () {
      SiloMediaRequest r(String id, String outcome, String created) =>
          SiloMediaRequest.fromJson(_record(id, outcome: outcome, created: created))!;
      expect(
        siloCurrentRequestFor(
          [r('a', 'declined', '2026-03-01T00:00:00Z'), r('b', 'active', '2026-01-01T00:00:00Z')],
          'movie',
          949,
        )!.id,
        'b',
      );
      expect(siloCurrentRequestFor([r('a', 'declined', '2026-03-01T00:00:00Z')], 'movie', 949)!.id, 'a');
      expect(siloCurrentRequestFor([r('a', 'cancelled', '2026-03-01T00:00:00Z')], 'movie', 949), isNull);
      expect(siloCurrentRequestFor([r('a', 'active', '2026-03-01T00:00:00Z')], 'series', 949), isNull);
    });
  });

  group('detail and submit', () {
    final detailJson = {
      'media_type': 'movie',
      'tmdb_id': 949,
      'imdb_id': 'tt0113277',
      'title': 'Heat',
      'overview': 'A crew.',
      'poster_path': '/heat.jpg',
      'year': 1995,
      'runtime': 170,
      'genres': ['Crime'],
      'cast': [
        {'name': 'Al Pacino', 'order': 0},
      ],
      'availability': 'missing',
      'request': {'requestable': true},
    };

    test('detail is read from /requests/detail/{media_type}/{tmdb_id}', () async {
      final c = client((_) => _json(detailJson));
      final detail = await c.requests.detail('movie', 949);
      expect(requests.single.url.path, '/api/v2/requests/detail/movie/949');
      expect(detail.title, 'Heat');
      expect(detail.cast, ['Al Pacino']);
      expect(detail.request.requestable, isTrue);
      expect(detail.display, isNull);
    });

    test('submit posts the title once and applies the answer', () async {
      final c = client((request) {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v2/requests');
        return _json(_record('1834729'), 201);
      });
      final detail = SiloRequestMediaDetail.fromJson(detailJson)!;
      final record = await c.requests.create(detail);
      expect(jsonDecode(requests.single.body), {
        'media_type': 'movie',
        'tmdb_id': 949,
        'imdb_id': 'tt0113277',
        'title': 'Heat',
        'year': 1995,
        'overview': 'A crew.',
        'poster_path': '/heat.jpg',
      });
      expect(record.id, '1834729');
      final updated = detail.withRecord(record);
      expect(updated.request.requestable, isFalse);
      expect(updated.display!.kind, SiloRequestDisplayKind.pending);
      expect(record.canCancel, isTrue);
    });

    test(
      'failures: a conflict carries its detail, a bare gateway error is uncertain, capability problems turn off',
      () async {
        final detail = SiloRequestMediaDetail.fromJson(detailJson)!;
        Future<SiloRequestFailure> failWith(http.Response response) async {
          final c = client((_) => response);
          try {
            await c.requests.create(detail);
          } on SiloRequestFailure catch (f) {
            return f;
          }
          fail('expected a failure');
        }

        final conflict = await failWith(_problem(409, 'conflict', detail: 'Already requested by someone'));
        expect(conflict.kind, SiloRequestFailureKind.refused);
        expect(conflict.detail, 'Already requested by someone');
        expect(conflict.statusCode, 409);
        expect((await failWith(http.Response('Bad gateway', 502))).kind, SiloRequestFailureKind.uncertain);
        expect((await failWith(_problem(409, 'capability_disabled'))).kind, SiloRequestFailureKind.disabled);
        expect((await failWith(_problem(422, 'validation_failed'))).kind, SiloRequestFailureKind.invalid);
        expect((await failWith(_json({'unexpected': true}, 201))).kind, SiloRequestFailureKind.uncertain);
        expect(requests.where((r) => r.method == 'POST'), hasLength(5), reason: 'never resent');
      },
    );

    test('a transport failure is uncertain and not resent', () async {
      final c = client((_) => throw http.ClientException('reset'));
      await expectLater(
        c.requests.create(SiloRequestMediaDetail.fromJson(detailJson)!),
        throwsA(isA<SiloRequestFailure>().having((f) => f.kind, 'kind', SiloRequestFailureKind.uncertain)),
      );
      expect(requests, hasLength(1));
    });

    test('cancel posts an empty body to /requests/{id}/cancel', () async {
      final c = client((_) => _json(_record('42', outcome: 'cancelled', state: 'cancelled')));
      final record = await c.requests.cancel('42');
      expect(requests.single.url.path, '/api/v2/requests/42/cancel');
      expect(jsonDecode(requests.single.body), <String, dynamic>{});
      expect(record.toRequestState().requestable, isTrue);
    });
  });

  group('My requests paging', () {
    test('follows next_cursor at 50 a page', () async {
      final c = client((request) {
        final cursor = request.url.queryParameters['cursor'];
        expect(request.url.queryParameters['limit'], '50');
        if (cursor == null) {
          return _json({
            'items': [_record('1')],
            'page': {'has_more': true, 'next_cursor': 'c2'},
          });
        }
        return _json({
          'items': [_record('2')],
          'page': {'has_more': false},
        });
      });
      final mine = await c.requests.mine();
      expect(mine.map((r) => r.id), ['1', '2']);
      expect(requests.map((r) => r.url.queryParameters['cursor']), [null, 'c2']);
    });

    test('a repeated or missing cursor fails the whole load', () async {
      final repeated = client(
        (_) => _json({
          'items': [_record('1')],
          'page': {'has_more': true, 'next_cursor': 'same'},
        }),
      );
      await expectLater(repeated.requests.mine(), throwsFormatException);
      final missing = client(
        (_) => _json({
          'items': [_record('1')],
          'page': {'has_more': true},
        }),
      );
      await expectLater(missing.requests.mine(), throwsFormatException);
    });
  });

  test('TMDB image paths load from TMDB', () {
    expect(siloRequestImageUrl('/a.jpg'), 'https://image.tmdb.org/t/p/w500/a.jpg');
    expect(siloRequestImageUrl('/a.jpg', backdrop: true), 'https://image.tmdb.org/t/p/w780/a.jpg');
    expect(siloRequestImageUrl('https://x/y.jpg'), 'https://x/y.jpg');
    expect(siloRequestImageUrl(''), isNull);
  });
}
