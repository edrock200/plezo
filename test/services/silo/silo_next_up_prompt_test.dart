import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_next_up_prompt.dart';

/// Show Next Up (Silo Android #994): the Play Next prompt opens the chosen
/// number of seconds before the end of the file, not at the credits marker.

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

Map<String, dynamic> _effective(Object? value, {String source = 'profile'}) => {
  'items': [
    {'key': SiloNextUpPrompt.settingKey, 'value': value, 'source': source},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('crossesPromptPoint', () {
    const duration = Duration(minutes: 40);
    bool crosses(Duration previous, Duration position, {int seconds = 30}) => SiloNextUpPrompt.crossesPromptPoint(
      previous: duration - previous,
      position: duration - position,
      duration: duration,
      promptSeconds: seconds,
    );

    test('playback across the point counts', () {
      expect(crosses(const Duration(seconds: 31), const Duration(seconds: 30)), isTrue);
      expect(crosses(const Duration(milliseconds: 30200), const Duration(milliseconds: 29700)), isTrue);
    });

    test('before or after the point, or a backward move, does not', () {
      expect(crosses(const Duration(seconds: 40), const Duration(seconds: 39)), isFalse);
      expect(crosses(const Duration(seconds: 29), const Duration(seconds: 28)), isFalse);
      expect(crosses(const Duration(seconds: 29), const Duration(seconds: 31)), isFalse);
    });

    test('a seek or resume past the point does not', () {
      expect(crosses(const Duration(minutes: 5), const Duration(seconds: 20)), isFalse);
      expect(crosses(const Duration(seconds: 34), const Duration(seconds: 29)), isFalse);
    });

    test('"At end" or an unknown duration never opens it early', () {
      expect(crosses(const Duration(seconds: 1), Duration.zero, seconds: 0), isFalse);
      expect(
        SiloNextUpPrompt.crossesPromptPoint(
          previous: const Duration(seconds: 1),
          position: const Duration(seconds: 2),
          duration: Duration.zero,
          promptSeconds: 30,
        ),
        isFalse,
      );
    });
  });

  test('countdownSeconds is the playback time left, rounded up', () {
    const duration = Duration(minutes: 40);
    expect(
      SiloNextUpPrompt.countdownSeconds(position: duration - const Duration(milliseconds: 29500), duration: duration),
      30,
    );
    expect(SiloNextUpPrompt.countdownSeconds(position: duration, duration: duration), 0);
    expect(SiloNextUpPrompt.countdownSeconds(position: duration + const Duration(seconds: 1), duration: duration), 0);
  });

  test('secondsFromEffective reads the value from any layer', () {
    expect(SiloNextUpPrompt.secondsFromEffective(_effective(10)), 10);
    expect(SiloNextUpPrompt.secondsFromEffective(_effective(0, source: 'default')), 0);
    expect(SiloNextUpPrompt.secondsFromEffective(_effective('45', source: 'server')), 45);
    expect(SiloNextUpPrompt.secondsFromEffective(_effective(-5)), isNull);
    expect(SiloNextUpPrompt.secondsFromEffective(_effective(null)), isNull);
    expect(SiloNextUpPrompt.secondsFromEffective({'items': <Object>[]}), isNull);
    expect(SiloNextUpPrompt.secondsFromEffective(null), isNull);
  });

  group('SiloClient.nextUpPromptSeconds', () {
    late List<http.Request> requests;
    late http.Response Function() answer;

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
    });

    SiloClient client() => SiloClient.forTesting(
      _connection(),
      headers: _headers,
      httpClient: MockClient((request) async {
        requests.add(request);
        return answer();
      }),
    );

    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('reads the profile\'s setting once, with the profile header', () async {
      answer = () => json(_effective(10));
      final c = client();
      expect(await c.nextUpPromptSeconds(), 10);
      expect(await c.nextUpPromptSeconds(), 10);
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.url.path, '/api/v2/settings/values/effective');
      expect(request.url.queryParametersAll['keys'], [SiloNextUpPrompt.settingKey]);
      expect(request.headers['X-Profile-Id'], 'p-owner');
    });

    test('"At end" is 0', () async {
      answer = () => json(_effective(0));
      expect(await client().nextUpPromptSeconds(), 0);
    });

    test('no value, or a failed read, means Silo\'s default of 30', () async {
      answer = () => json({'items': <Object>[]});
      expect(await client().nextUpPromptSeconds(), SiloNextUpPrompt.defaultSeconds);
      answer = () => json({'title': 'boom'}, 500);
      expect(await client().nextUpPromptSeconds(), 30);
      answer = () => json({}, 404);
      expect(await client().nextUpPromptSeconds(), 30);
    });
  });
}
