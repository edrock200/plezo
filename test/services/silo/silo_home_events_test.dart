import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/home_watch_state.dart';
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_catalog_strings.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_home_events.dart';

import '../../test_helpers/prefs.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection({String baseUrl = 'https://silo.example.com'}) => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: baseUrl,
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

Map<String, dynamic> _ticketBody({String ticket = 'tkt-1', int expires = 30, int lifetime = 300}) => {
  'ticket': ticket,
  'expires_in': expires,
  'max_connection_seconds': lifetime,
  'protocol': 'silo.events.v2',
};

const _ticket = SiloEventsTicket(ticket: 'tkt-1', expiresIn: 30, maxConnectionSeconds: 300);

String _frame(Map<String, Object?> frame) => jsonEncode(frame);

String _subscribed([List<String> channels = const ['user_state']]) =>
    _frame({'type': 'subscribed', 'channels': channels, 'rejected': <Object>[]});

String _userState(String profileId, {String change = 'watched'}) => _frame({
  'type': 'event',
  'channel': 'user_state',
  'event': 'user_state.changed',
  'event_id': '01J',
  'timestamp': '2026-11-20T10:00:00Z',
  'data': {'profile_id': profileId, 'content_id': 'movie:heat-1995', 'change': change},
});

/// A scripted events socket.
class _FakeConnection implements SiloEventsConnection {
  final _frames = StreamController<String>();
  final List<String> sent = [];
  bool closed = false;
  int? code;

  @override
  Stream<String> get frames => _frames.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  int? get closeCode => code;

  void push(String frame) {
    if (!closed) _frames.add(frame);
  }

  /// The server closes the socket.
  void serverClose([int? closeCode]) {
    code = closeCode;
    unawaited(close());
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_frames.close());
  }
}

Future<void> _settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => SiloCatalogStrings.load(AppLocale.en));

  group('contract', () {
    test('the socket URL keeps a path prefix and selects user_state; no credentials in it', () {
      expect(
        SiloHomeEvents.socketUrl('https://silo.example.com').toString(),
        'wss://silo.example.com/api/v2/events/ws?channels=user_state',
      );
      expect(
        SiloHomeEvents.socketUrl('http://10.0.0.2:8096/silo/').toString(),
        'ws://10.0.0.2:8096/silo/api/v2/events/ws?channels=user_state',
      );
      expect(jsonDecode(SiloHomeEvents.subscribeFrame()), {
        'type': 'subscribe',
        'channels': ['user_state'],
      });
    });

    test('tickets are checked as Silo Android checks them', () {
      expect(SiloEventsTicket.parse(_ticketBody())?.maxConnectionSeconds, 300);
      expect(SiloEventsTicket.parse({..._ticketBody(), 'protocol': 'silo.room.v2'}), isNull);
      expect(SiloEventsTicket.parse(_ticketBody(expires: 0)), isNull);
      expect(SiloEventsTicket.parse(_ticketBody(expires: 31)), isNull);
      expect(SiloEventsTicket.parse(_ticketBody(lifetime: 14400)), isNull);
      expect(SiloEventsTicket.parse(_ticketBody(ticket: '')), isNull);
      expect(SiloEventsTicket.parse(_ticketBody(ticket: 'a b')), isNull, reason: 'travels in a header unchanged');
      expect(SiloEventsTicket.parse(_ticketBody(ticket: 'a,b')), isNull);
      expect(SiloEventsTicket.parse('nope'), isNull);
      expect(SiloEventsTicket.parse(_ticketBody()).toString(), isNot(contains('tkt-1')), reason: 'never logged');
    });

    test('frames: subscribed, user_state.changed and access_changed; the rest is ignored', () {
      expect(SiloHomeEvent.parse(_subscribed())?.subscribedToUserState, isTrue);
      expect(SiloHomeEvent.parse(_subscribed(['catalog']))?.subscribedToUserState, isFalse);
      final change = SiloHomeEvent.parse(_userState('p-owner', change: 'progress'))!;
      expect(change.kind, SiloHomeEventKind.userStateChanged);
      expect(change.profileId, 'p-owner');
      expect(change.change, 'progress');
      expect(SiloHomeEvent.parse('{"type":"access_changed"}')?.kind, SiloHomeEventKind.accessChanged);
      expect(SiloHomeEvent.parse('{"type":"hello","available_channels":["user_state"]}'), isNull);
      expect(SiloHomeEvent.parse('{"type":"snapshot","channel":"user_state","data":null}'), isNull);
      expect(
        SiloHomeEvent.parse('{"type":"event","channel":"catalog","event":"catalog.item.changed","data":{}}'),
        isNull,
      );
      expect(
        SiloHomeEvent.parse('{"type":"event","channel":"user_state","event":"user_state.changed","data":{}}'),
        isNull,
      );
      expect(SiloHomeEvent.parse('not json'), isNull);
      expect(SiloHomeEvent.parse('[1]'), isNull);
    });

    test('transient Home read failures: timeouts, lost connections, 408, 429 and 5xx', () {
      MediaServerHttpException status(int code) =>
          MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: code, message: '');
      expect(SiloClient.isTransientHomeReadFailure(TimeoutException('slow')), isTrue);
      expect(
        SiloClient.isTransientHomeReadFailure(
          MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: ''),
        ),
        isTrue,
      );
      for (final code in [408, 429, 500, 502, 503, 504]) {
        expect(SiloClient.isTransientHomeReadFailure(status(code)), isTrue, reason: '$code');
      }
      for (final code in [400, 401, 403, 404, 422]) {
        expect(SiloClient.isTransientHomeReadFailure(status(code)), isFalse, reason: '$code');
      }
      expect(
        SiloClient.isTransientHomeReadFailure(
          MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: ''),
        ),
        isFalse,
      );
      expect(SiloClient.isTransientHomeReadFailure(StateError('bug')), isFalse);
    });
  });

  group('SiloHomeEventsWatcher', () {
    late List<_FakeConnection> connections;
    late List<HomeWatchStateSignal> signals;
    late int mints;
    late bool connectFails;
    late Object? mintError;

    setUp(() {
      connections = [];
      signals = [];
      mints = 0;
      connectFails = false;
      mintError = null;
    });

    SiloHomeEventsWatcher watcher({
      Duration subscribeTimeout = const Duration(seconds: 15),
      Duration pollInterval = const Duration(minutes: 2),
      bool Function()? usable,
    }) {
      final w = SiloHomeEventsWatcher(
        url: SiloHomeEvents.socketUrl('https://silo.example.com'),
        profileId: 'p-owner',
        mintTicket: () async {
          mints++;
          final error = mintError;
          if (error != null) throw error;
          return _ticket;
        },
        connect: (url, ticket) async {
          expect(url.toString(), 'wss://silo.example.com/api/v2/events/ws?channels=user_state');
          if (connectFails) return null;
          final connection = _FakeConnection();
          connections.add(connection);
          return connection;
        },
        onSignal: signals.add,
        isClientUsable: usable,
        initialBackoff: const Duration(milliseconds: 10),
        maxBackoff: const Duration(milliseconds: 40),
        subscribeTimeout: subscribeTimeout,
        pollInterval: pollInterval,
      );
      addTearDown(w.stop);
      return w;
    }

    test('subscribes to user_state and reports only this profile\'s changes', () async {
      final w = watcher()..start();
      await _settle();
      final socket = connections.single;
      expect(socket.sent.map(jsonDecode), [
        {
          'type': 'subscribe',
          'channels': ['user_state'],
        },
      ]);
      // Nothing counts before the subscription is confirmed.
      socket.push(_userState('p-owner'));
      await _settle();
      expect(signals, isEmpty);

      socket.push(_subscribed());
      await _settle();
      expect(w.isLive, isTrue);
      expect(signals, isEmpty, reason: 'the first subscription follows a Home read');

      socket.push(_userState('p-kids'));
      socket.push(_userState('p-owner', change: 'progress'));
      await _settle();
      expect(signals, [HomeWatchStateSignal.changed]);
    });

    test('reconnects with a fresh ticket after a close and catches up once subscribed again', () async {
      final w = watcher()..start();
      await _settle();
      connections.single.push(_subscribed());
      await _settle();
      connections.single.serverClose(1000);
      await _settle(5);
      expect(w.isLive, isFalse);
      await _settle(40);
      expect(mints, 2);
      expect(connections, hasLength(2));
      connections.last.push(_subscribed());
      await _settle();
      expect(signals, [HomeWatchStateSignal.reconnected]);
    });

    test(
      'backs off 1 s doubling to 30 s (scaled) while connections fail, and starts over after one subscribed',
      () async {
        connectFails = true;
        watcher().start();
        // Waits of 10, 20, 40, 40, … ms: a few tries early, then no faster than the cap.
        await _settle(60);
        final early = mints;
        expect(early, greaterThanOrEqualTo(2));
        await _settle(200);
        expect(mints - early, inInclusiveRange(1, 6), reason: 'capped at the maximum');
      },
    );

    test('an access change reconnects at once and asks Home to read again', () async {
      watcher().start();
      await _settle();
      connections.single.push(_subscribed());
      await _settle();
      connections.single.push('{"type":"access_changed"}');
      connections.single.serverClose(4001);
      await _settle(5);
      expect(signals, [HomeWatchStateSignal.changed]);
      expect(mints, 2, reason: 'no backoff after an access change');
    });

    test('a 4001 close without the frame counts as an access change', () async {
      watcher().start();
      await _settle();
      connections.single.push(_subscribed());
      await _settle();
      connections.single.serverClose(4001);
      await _settle(5);
      expect(signals, [HomeWatchStateSignal.changed]);
    });

    test('a socket that never subscribes is closed and tried again', () async {
      watcher(subscribeTimeout: const Duration(milliseconds: 20)).start();
      await _settle(30);
      expect(connections.first.closed, isTrue);
      await _settle(40);
      expect(connections.length, greaterThanOrEqualTo(2));
    });

    test('a server without the socket stops trying; a periodic check stands in', () async {
      mintError = const SiloEventsUnsupported(404);
      final w = watcher(pollInterval: const Duration(milliseconds: 25))..start();
      await _settle(70);
      expect(w.isUnsupported, isTrue);
      expect(mints, 1);
      expect(signals, isNotEmpty);
      expect(signals.toSet(), {HomeWatchStateSignal.poll});
    });

    test('no periodic check while a socket is live', () async {
      watcher(pollInterval: const Duration(milliseconds: 25)).start();
      await _settle(5);
      connections.single.push(_subscribed());
      await _settle(70);
      expect(signals, isEmpty);
    });

    test('stop closes the socket and nothing more is minted or reported', () async {
      final w = watcher(pollInterval: const Duration(milliseconds: 15))..start();
      await _settle(5);
      final socket = connections.single..push(_subscribed());
      await _settle(5);
      w.stop();
      final reported = signals.length;
      expect(socket.closed, isTrue);
      socket.push(_userState('p-owner'));
      await _settle(60);
      expect(mints, 1);
      expect(signals, hasLength(reported));
    });

    test('a closed or signed-out client ends the watch', () async {
      var usable = true;
      watcher(usable: () => usable).start();
      await _settle();
      connections.single.push(_subscribed());
      await _settle();
      usable = false;
      connections.single.serverClose(1000);
      await _settle(60);
      expect(mints, 1);
    });
  });

  group('SiloClient', () {
    late AppDatabase db;
    late List<http.Request> requests;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
    });
    tearDown(() => db.close());

    SiloClient client(Future<http.Response> Function(http.Request request) handler) {
      final c = SiloClient.forTesting(
        _connection(),
        headers: _headers,
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
      );
      addTearDown(c.close);
      return c;
    }

    test('mints the events ticket with the profile and opens the socket with it', () async {
      final opened = <(Uri, SiloEventsTicket)>[];
      final c = client((request) async {
        if (request.url.path == '/api/v2/events/ws-ticket') return _json(_ticketBody(ticket: 'abc'));
        return http.Response('', 404);
      });
      final socket = _FakeConnection();
      c.eventsConnector = (url, ticket) async {
        opened.add((url, ticket));
        return socket;
      };
      final signals = <HomeWatchStateSignal>[];
      final watch = c.watchHomeWatchState(signals.add)!;
      addTearDown(watch.stop);
      await _settle();

      final mint = requests.singleWhere((r) => r.url.path == '/api/v2/events/ws-ticket');
      expect(mint.method, 'POST');
      expect(mint.headers['x-profile-id'], 'p-owner');
      expect(mint.headers['authorization'], 'Bearer acc-1');
      expect(opened.single.$1.toString(), 'wss://silo.example.com/api/v2/events/ws?channels=user_state');
      expect(opened.single.$2.ticket, 'abc');

      socket.push(_subscribed());
      socket.push(_userState('p-owner'));
      await _settle();
      expect(signals, [HomeWatchStateSignal.changed]);
    });

    test('a server without the ticket route is not asked again', () async {
      final c = client((request) async => http.Response('', 404));
      c.eventsConnector = (url, ticket) async => fail('no socket without a ticket');
      final watch = c.watchHomeWatchState((_) {})! as SiloHomeEventsWatcher;
      addTearDown(watch.stop);
      await _settle(40);
      expect(watch.isUnsupported, isTrue);
      expect(requests.where((r) => r.url.path == '/api/v2/events/ws-ticket'), hasLength(1));
    });

    test('a closed client starts no watch', () {
      final c = client((request) async => http.Response('', 404));
      c.close();
      expect(c.watchHomeWatchState((_) {}), isNull);
    });

    Map<String, dynamic> section(String id, {int total = 2, List<Object> items = const []}) => {
      'id': id,
      'section_type': 'recently_added',
      'title': 'Row $id',
      'total_count': total,
      'items': items,
    };

    Map<String, dynamic> card(String id, {bool played = false}) => {
      'content_id': id,
      'type': 'movie',
      'title': id,
      if (played) 'user_state': {'played': true},
    };

    test('a section whose items fail for a transient reason keeps its rows and marks the read incomplete', () async {
      var itemsStatus = 200;
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path == '/api/v2/home/sections') {
          return _json({
            'sections': [
              section('inline', items: [card('movie:a')]),
              section('lazy'),
            ],
          });
        }
        if (path == '/api/v2/home/sections/lazy/items') {
          if (itemsStatus != 200) return _json({'title': 'busy'}, itemsStatus);
          return _json({
            'items': [card('movie:b'), card('movie:c')],
          });
        }
        return http.Response('', 404);
      });

      var hubs = await c.fetchGlobalHubs();
      expect(hubs.map((h) => h.id), ['home:inline', 'home:lazy']);
      expect(c.lastHomeReadIncomplete, isFalse);

      itemsStatus = 503;
      hubs = await c.fetchGlobalHubs();
      expect(hubs.map((h) => h.id), ['home:inline', 'home:lazy'], reason: 'the row keeps what it showed');
      expect(hubs.last.items.map((i) => i.id), ['movie:b', 'movie:c']);
      expect(c.lastHomeReadIncomplete, isTrue);

      itemsStatus = 404;
      hubs = await c.fetchGlobalHubs();
      expect(hubs.map((h) => h.id), ['home:inline'], reason: 'a lasting failure is not retried');
      expect(c.lastHomeReadIncomplete, isFalse);

      itemsStatus = 200;
      await c.fetchGlobalHubs();
      expect(c.lastHomeReadIncomplete, isFalse);
    });

    test('a failed Home read is incomplete only for a transient reason', () async {
      var status = 503;
      final c = client((request) async {
        if (request.url.path == '/api/v2/home/sections') return _json({'title': 'x'}, status);
        return http.Response('', 404);
      });
      expect(await c.fetchGlobalHubs(), isEmpty);
      expect(c.lastHomeReadIncomplete, isTrue);
      status = 403;
      expect(await c.fetchGlobalHubs(), isEmpty);
      expect(c.lastHomeReadIncomplete, isFalse);
    });
  });

  group('Home end to end', () {
    late AppDatabase db;
    late MultiServerManager manager;
    late MultiServerProvider multiServer;
    late HiddenLibrariesProvider hidden;
    late LibrariesProvider libraries;
    late DiscoverProvider discover;
    late List<http.Request> requests;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
    });
    tearDown(() => db.close());

    var played = false;
    var sectionsStatus = 200;

    Future<SiloClient> setUpHome() async {
      played = false;
      sectionsStatus = 200;
      final c = SiloClient.forTesting(
        _connection(),
        headers: _headers,
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = Uri.decodeComponent(request.url.path);
          if (path == '/api/v2/home/sections') {
            if (sectionsStatus != 200) return _json({'title': 'busy'}, sectionsStatus);
            return _json({
              'sections': [
                {
                  'id': 'recent',
                  'section_type': 'recently_added',
                  'title': 'Recently Added Movies',
                  'total_count': 1,
                  'items': [
                    {
                      'content_id': 'movie:heat-1995',
                      'type': 'movie',
                      'title': 'Heat',
                      if (played) 'user_state': {'played': true},
                    },
                  ],
                },
              ],
            });
          }
          if (path == '/api/v2/user/libraries') return _json({'items': <Object>[]});
          if (path == '/api/v2/events/ws-ticket') return _json(_ticketBody());
          return http.Response('', 404);
        }),
      );
      manager = MultiServerManager()..debugRegisterClientForTesting(c);
      multiServer = MultiServerProvider(manager, DataAggregationService(manager));
      hidden = HiddenLibrariesProvider();
      await hidden.ensureInitialized();
      libraries = LibrariesProvider();
      discover = DiscoverProvider(
        multiServer,
        hidden,
        libraries,
        profileId: 'profile-a',
        isProfileBinding: () => false,
        watchStateEventDebounce: const Duration(milliseconds: 10),
        watchStateRetryBase: const Duration(milliseconds: 10),
      );
      addTearDown(() {
        discover.dispose();
        libraries.dispose();
        hidden.dispose();
        multiServer.dispose();
        manager.dispose();
        c.close();
      });
      return c;
    }

    int homeReads() => requests.where((r) => r.url.path == '/api/v2/home/sections').length;

    bool heatPlayed() => discover.hubs.single.items.single.viewCount == 1;

    test('a watched mark on another device updates the card while Home is shown', () async {
      final c = await setUpHome();
      final socket = _FakeConnection();
      c.eventsConnector = (url, ticket) async => socket;
      await discover.load();
      expect(heatPlayed(), isFalse);

      discover.setHomeVisible(true);
      await _settle();
      expect(requests.where((r) => r.url.path == '/api/v2/events/ws-ticket'), hasLength(1));
      socket.push(_subscribed());
      await _settle();

      played = true;
      final before = homeReads();
      socket.push(_userState('p-owner'));
      await _settle(60);
      expect(homeReads(), greaterThan(before));
      expect(heatPlayed(), isTrue);

      // Hidden (a detail page or the player covers Home): the socket closes.
      discover.setHomeVisible(false);
      expect(socket.closed, isTrue);
    });

    test('Home shown again re-reads Silo rows; a transient failure is retried until it reads', () async {
      final c = await setUpHome();
      // No events socket here: only the return and the retries read.
      c.eventsConnector = (url, ticket) async => null;
      await discover.load();
      discover.setHomeVisible(true);
      played = true;
      sectionsStatus = 503;
      final before = homeReads();

      await discover.refreshHomeWatchState(HomeWatchStateTrigger.shown);
      expect(heatPlayed(), isFalse, reason: 'a failed read keeps the rows shown');
      expect(homeReads(), greaterThan(before));

      sectionsStatus = 200;
      await _settle(80);
      expect(heatPlayed(), isTrue);
    });
  });
}
