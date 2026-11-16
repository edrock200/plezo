import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_memberships.dart';

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

MediaItem _movie({Map<String, dynamic>? userState, bool? isFavorite}) => MediaItem.silo(
  id: 'movie:m1',
  kind: MediaKind.movie,
  title: 'Heat',
  serverId: 'srv-1',
  isFavorite: isFavorite,
  raw: {'content_id': 'movie:m1', 'type': 'movie', 'user_state': ?userState},
);

http.Response _problem(int status, String detail) => http.Response(
  jsonEncode({'type': 'https://siloserver.org/problems/conflict', 'title': 'Conflict', 'detail': detail}),
  status,
  headers: {'content-type': 'application/problem+json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('SiloClient membership writes', () {
    late List<http.Request> requests;
    late http.Response Function(http.Request) answer;

    SiloClient client() => SiloClient.forTesting(
      _connection(),
      headers: _headers,
      httpClient: MockClient((request) async {
        requests.add(request);
        return answer(request);
      }),
    );

    setUp(() {
      requests = [];
      answer = (_) => http.Response('', 204);
    });

    test('add and remove use PUT and DELETE on /watchlist and /favorites with the profile', () async {
      final c = client();
      await c.setWatchlist(_movie(), true);
      await c.setWatchlist(_movie(), false);
      await c.setFavorite(_movie(), true);
      await c.setMembership(_movie(), SiloMembership.favorite, false);

      expect(
        [for (final r in requests) '${r.method} ${Uri.decodeComponent(r.url.path)}'],
        [
          'PUT /api/v2/watchlist/movie:m1',
          'DELETE /api/v2/watchlist/movie:m1',
          'PUT /api/v2/favorites/movie:m1',
          'DELETE /api/v2/favorites/movie:m1',
        ],
      );
      expect(requests.first.headers['X-Profile-Id'], 'p-owner');
    });

    test('a refusal throws with the problem', () async {
      answer = (_) => _problem(409, 'Watchlist is full');
      await expectLater(
        client().setWatchlist(_movie(), true),
        throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'status', 409)),
      );
    });
  });

  group('SiloMembershipStore', () {
    late List<(SiloMembership, bool)> sent;
    late List<Completer<void>> answers;

    SiloMembershipStore store() => SiloMembershipStore(
      serverId: 'srv-1',
      write: (item, kind, value) {
        sent.add((kind, value));
        final answer = Completer<void>();
        answers.add(answer);
        return answer.future;
      },
    );

    setUp(() {
      sent = [];
      answers = [];
    });

    test('reads user_state from the item', () {
      final s = store();
      expect(s.isMember(_movie(userState: {'in_watchlist': true}), SiloMembership.watchlist), isTrue);
      expect(s.isMember(_movie(userState: {'in_watchlist': false}), SiloMembership.watchlist), isFalse);
      expect(s.isMember(_movie(isFavorite: true), SiloMembership.favorite), isTrue);
      expect(s.isMember(_movie(userState: {'is_favorite': true}), SiloMembership.favorite), isTrue);
      expect(s.isMember(_movie(), SiloMembership.favorite), isFalse);
    });

    test('a press changes the state at once and reports the server answer', () async {
      final s = store();
      final changes = <SiloMembershipChange>[];
      final sub = SiloMembershipStore.changes.listen(changes.add);
      addTearDown(sub.cancel);
      var notified = 0;
      s.addListener(() => notified++);

      final press = s.toggle(_movie(), SiloMembership.watchlist);
      expect(s.isMember(_movie(), SiloMembership.watchlist), isTrue);
      expect(notified, 1);
      answers.single.complete();
      final outcome = await press;

      expect(outcome!.ok, isTrue);
      expect(outcome.message, t.explore.addedToWatchlist);
      await Future<void>.delayed(Duration.zero);
      expect(changes.single.serverId, 'srv-1');
      expect(changes.single.kind, SiloMembership.watchlist);
      expect(changes.single.value, isTrue);
    });

    test("a refusal rolls back and carries the server's reason", () async {
      final s = store();
      final item = _movie(userState: {'is_favorite': true});
      final press = s.toggle(item, SiloMembership.favorite);
      expect(s.isMember(item, SiloMembership.favorite), isFalse);
      answers.single.completeError(
        MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          statusCode: 409,
          responseData: {'detail': 'Favorites are read-only for this profile'},
          message: 'HTTP 409',
        ),
      );
      final outcome = await press;

      expect(outcome!.ok, isFalse);
      expect(s.isMember(item, SiloMembership.favorite), isTrue, reason: 'back to what the server confirmed');
      expect(outcome.message, "Couldn't remove from Favorites. Favorites are read-only for this profile");
    });

    test('a refusal without a reason says Try again.', () async {
      final s = store();
      final press = s.toggle(_movie(), SiloMembership.watchlist);
      answers.single.completeError(StateError('boom'));
      expect((await press)!.message, "Couldn't add to Watchlist. Try again.");
    });

    test('presses during a write are queued; the latest wins and is sent after the first answers', () async {
      final s = store();
      final first = s.toggle(_movie(), SiloMembership.watchlist); // on
      expect(await Future.value(s.toggle(_movie(), SiloMembership.watchlist)), isNull); // off, queued
      expect(await Future.value(s.toggle(_movie(), SiloMembership.watchlist)), isNull); // on again, queued
      expect(sent, [(SiloMembership.watchlist, true)]);

      answers[0].complete();
      final outcome = await first;
      expect(sent, [(SiloMembership.watchlist, true)], reason: 'the queued press matches what was confirmed');
      expect(outcome!.value, isTrue);
      expect(s.isMember(_movie(), SiloMembership.watchlist), isTrue);
    });

    test('a queued press that changes the outcome is sent next', () async {
      final s = store();
      final first = s.toggle(_movie(), SiloMembership.watchlist); // on
      expect(await s.toggle(_movie(), SiloMembership.watchlist), isNull); // off, queued
      answers[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(sent, [(SiloMembership.watchlist, true), (SiloMembership.watchlist, false)]);
      answers[1].complete();
      final outcome = await first;
      expect(outcome!.value, isFalse);
      expect(outcome.message, t.explore.removedFromWatchlist);
      expect(s.isMember(_movie(), SiloMembership.watchlist), isFalse);
    });
  });
}
