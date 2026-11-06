import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_calendar.dart';
import 'package:plezy/services/silo/silo_client.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection() => SiloConnection(
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

Map<String, dynamic> _episode(
  String id, {
  String localDate = '2026-11-10',
  String? airAt,
  String? airTime,
  List<String> badges = const [],
  bool watched = false,
}) => {
  'content_id': id,
  'type': 'episode',
  'title': 'Severance',
  'episode_title': 'Hello, Ms. Cobel',
  'series_id': 'series:severance',
  'season_number': 2,
  'episode_number': 1,
  'air_date': localDate,
  'air_time': ?airTime,
  'air_at': ?airAt,
  'local_air_date': localDate,
  'poster_url': '/api/v2/images/p.jpg?sig=abc',
  'watched': watched,
  'badges': badges,
};

void main() {
  group('badges (Silo Android #722)', () {
    test('known badges in the server order, each once; unknown ones skipped', () {
      expect(
        siloCalendarBadges(['season_premiere', 'finale', 'series_finale', 'mystery', 'series_premiere', null, 3]),
        [SiloCalendarBadge.newSeason, SiloCalendarBadge.finale, SiloCalendarBadge.premiere],
      );
      expect(siloCalendarBadges(['digital', 'PHYSICAL']), [SiloCalendarBadge.digital, SiloCalendarBadge.physical]);
      expect(siloCalendarBadges(const []), isEmpty);
    });
  });

  group('air times', () {
    test('air_at is shown on the device clock', () {
      final item = SiloCalendarItem.fromJson(_episode('e1', airAt: '2026-11-10T02:05:00Z', airTime: '21:05'))!;
      final local = DateTime.parse('2026-11-10T02:05:00Z').toLocal();
      expect(item.airClock!.hour, local.hour);
      expect(item.airClock!.minute, 5);
      final h12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
      expect(item.airTimeLabel(use24HourClock: false), '$h12:05 ${local.hour >= 12 ? 'PM' : 'AM'}');
      expect(item.airTimeLabel(use24HourClock: true), '${local.hour.toString().padLeft(2, '0')}:05');
    });

    test('air_at with a numeric offset is the same instant', () {
      final a = SiloCalendarItem.fromJson(_episode('e1', airAt: '2026-06-09T21:00:00-04:00'))!;
      expect(a.airAt!.isAtSameMomentAs(DateTime.utc(2026, 6, 10, 1)), isTrue);
    });

    test('without air_at the network wall clock is shown as it is; midnight means no time', () {
      final wall = SiloCalendarItem.fromJson(_episode('e1', airTime: '21:05'))!;
      expect(wall.airTimeLabel(use24HourClock: false), '9:05 PM');
      expect(wall.airTimeLabel(use24HourClock: true), '21:05');
      expect(SiloCalendarItem.fromJson(_episode('e1', airTime: '00:00'))!.airClock, isNull);
      expect(SiloCalendarItem.fromJson(_episode('e1', airTime: 'soon'))!.airClock, isNull);
      expect(SiloCalendarItem.fromJson(_episode('e1'))!.airClock, isNull);
    });
  });

  group('time zone', () {
    test('the host zone reads as an IANA-style name or none', () {
      // DateTime.timeZoneName comes from the host; check the helper's
      // decisions through an offset-only reading.
      final zone = siloCalendarTimeZone(DateTime.now());
      expect(zone == null || zone.contains('/'), isTrue, reason: 'got $zone');
    });

    test('whole-hour offsets become Etc/GMT names (west is positive)', () {
      expect(siloCalendarTimeZone(_FakeNow(const Duration(hours: -5), 'EST')), 'Etc/GMT+5');
      expect(siloCalendarTimeZone(_FakeNow(const Duration(hours: 1), 'CET')), 'Etc/GMT-1');
      expect(siloCalendarTimeZone(_FakeNow(Duration.zero, 'GMT')), 'Etc/UTC');
      expect(siloCalendarTimeZone(_FakeNow(Duration.zero, 'WET')), 'Etc/UTC');
      expect(siloCalendarTimeZone(_FakeNow(const Duration(hours: 5, minutes: 30), 'IST')), isNull);
      expect(siloCalendarTimeZone(_FakeNow(const Duration(hours: -4), 'America/New_York')), 'America/New_York');
      expect(siloCalendarTimeZone(_FakeNow(const Duration(hours: -8), 'Pacific Standard Time')), 'Etc/GMT+8');
    });
  });

  group('weeks', () {
    test('weeks start on Monday', () {
      expect(siloCalendarWeekStart(DateTime(2026, 11, 6)), DateTime(2026, 11, 2));
      expect(siloCalendarWeekStart(DateTime(2026, 11, 2, 23)), DateTime(2026, 11, 2));
      expect(siloCalendarWeekStart(DateTime(2026, 11, 8)), DateTime(2026, 11, 2));
      expect(siloCalendarYmd(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('events land on their device-local day; padding days and duplicates are dropped', () {
      final instant = DateTime.parse('2026-11-04T12:00:00Z');
      final events = [
        SiloCalendarItem.fromJson(_episode('a', localDate: '2026-11-03'))!,
        SiloCalendarItem.fromJson(_episode('b', airAt: instant.toIso8601String(), localDate: '2026-11-01'))!,
        SiloCalendarItem.fromJson(_episode('pad', localDate: '2026-11-01'))!,
        SiloCalendarItem.fromJson(_episode('a', localDate: '2026-11-03'))!,
        SiloCalendarItem.fromJson(_episode('pad2', localDate: '2026-11-09'))!,
      ];
      final week = SiloCalendarWeek.from(DateTime(2026, 11, 2), events);
      final localB = instant.toLocal();
      expect(week.eventCount, 2);
      expect(week.days[1].map((e) => e.contentId), ['a']);
      expect(week.days[localB.day - 2].map((e) => e.contentId), contains('b'));
    });

    test('timed events are ordered by instant within a day', () {
      final events = [
        SiloCalendarItem.fromJson(_episode('late', airAt: '2026-11-04T12:20:00Z', localDate: '2026-11-04'))!,
        SiloCalendarItem.fromJson(_episode('early', airAt: '2026-11-04T12:00:00Z', localDate: '2026-11-04'))!,
      ];
      final week = SiloCalendarWeek.from(DateTime(2026, 11, 2), events);
      final day = week.days.firstWhere((d) => d.isNotEmpty);
      expect(day.map((e) => e.contentId), ['early', 'late']);
    });
  });

  test('spoiler rule hides an unwatched episode title only while Hide spoilers is on', () {
    final unwatched = SiloCalendarItem.fromJson(_episode('e1'))!;
    final watched = SiloCalendarItem.fromJson(_episode('e2', watched: true))!;
    expect(unwatched.episodeTitleShown(hideSpoilers: false), 'Hello, Ms. Cobel');
    expect(unwatched.episodeTitleShown(hideSpoilers: true), isNull);
    expect(watched.episodeTitleShown(hideSpoilers: true), 'Hello, Ms. Cobel');
  });

  test('an episode opens its own page, falling back to its series; a movie its own page', () {
    final episode = SiloCalendarItem.fromJson(_episode('episode:x'))!;
    expect(episode.isEpisode, isTrue);
    final premiere = SiloCalendarItem.fromJson({..._episode('season:x'), 'type': 'season_premiere'})!;
    expect(premiere.isEpisode, isTrue);
    final movie = SiloCalendarItem.fromJson({
      'content_id': 'movie:m',
      'type': 'movie',
      'title': 'Heat',
      'air_date': '2026-11-05',
      'local_air_date': '2026-11-05',
      'badges': ['digital'],
    })!;
    expect(movie.isEpisode, isFalse);
    expect(movie.isMovie, isTrue);
    expect(movie.badges, [SiloCalendarBadge.digital]);
    expect(SiloCalendarItem.fromJson({'content_id': ' ', 'type': 'movie'}), isNull);
  });

  group('fetchWeek', () {
    late List<http.Request> requests;
    SiloClient client(FutureOr<http.Response> Function(http.Request request) handler) => SiloClient.forTesting(
      _connection(),
      headers: _headers,
      httpClient: MockClient((request) async {
        requests.add(request);
        return handler(request);
      }),
    );

    setUp(() => requests = []);

    test('asks for the padded week with the filter and zone and resolves artwork against the origin', () async {
      final c = client(
        (_) => http.Response(
          jsonEncode({
            'events': [
              {
                'date': '2026-11-03',
                'items': [
                  _episode('e1', localDate: '2026-11-03', badges: ['season_premiere']),
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final week = await c.calendar.fetchWeek(
        DateTime(2026, 11, 2),
        filter: SiloCalendarFilter.trending,
        now: _FakeNow(const Duration(hours: -5), 'EST'),
      );
      final query = requests.single.url.queryParameters;
      expect(requests.single.url.path, '/base/api/v2/calendar');
      expect(query, {'start': '2026-11-01', 'end': '2026-11-09', 'filter': 'trending', 'timezone': 'Etc/GMT+5'});
      expect(requests.single.headers['X-Profile-Id'], 'p-owner');
      final event = week.days[1].single;
      expect(event.badges, [SiloCalendarBadge.newSeason]);
      expect(event.posterUrl, 'https://silo.example.com/api/v2/images/p.jpg?sig=abc');
    });

    test('an answer without events or day items fails', () async {
      final noEvents = client((_) => http.Response('{}', 200, headers: {'content-type': 'application/json'}));
      await expectLater(noEvents.calendar.fetchWeek(DateTime(2026, 11, 2)), throwsFormatException);
      final noItems = client(
        (_) => http.Response(
          jsonEncode({
            'events': [
              {'date': '2026-11-03'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await expectLater(noItems.calendar.fetchWeek(DateTime(2026, 11, 2)), throwsFormatException);
    });
  });
}

/// A [DateTime] reporting a chosen zone name and offset.
class _FakeNow implements DateTime {
  _FakeNow(this.timeZoneOffset, this.timeZoneName);

  @override
  final Duration timeZoneOffset;

  @override
  final String timeZoneName;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
