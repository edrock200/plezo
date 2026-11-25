import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/api_cache.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';

import '../../test_helpers/prefs.dart';
import 'tofa_fixtures.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('compound id names server, account and Tofa profile', () {
    final connection = tofaConnection();
    expect(connection.id, 'srv-1/u-1/p-1');
    expect(connection.kind, MediaBackend.tofa);
    expect(connection.displayName, 'Laura · tofa.example.com');
  });

  test('config JSON round-trips every field', () {
    final original = tofaConnection(
      profileToken: 'ptok',
      accessTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
    ).copyWith(profileTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(1790000000000), isAdministrator: true);
    final restored = TofaConnection.fromConfigJson(
      id: original.id,
      json: original.toConfigJson(),
      createdAt: original.createdAt,
    );
    expect(restored.toConfigJson(), original.toConfigJson());
    expect(restored.connectUrl, tofaCloud);
    expect(restored.profileToken, 'ptok');
    expect(restored.profileIsLocked, isTrue);
    expect(restored.isAdministrator, isTrue);
  });

  test('copyWith rotates tokens and keeps identity', () {
    final rotated = tofaConnection(
      profileToken: 'ptok',
    ).copyWith(accessToken: 'acc-2', refreshToken: 'ref-2', clearProfileToken: true);
    expect(rotated.id, 'srv-1/u-1/p-1');
    expect(rotated.refreshToken, 'ref-2');
    expect(rotated.profileToken, isNull);
  });

  test('credential vault encrypts the access, refresh and profile tokens at rest', () async {
    final config = tofaConnection(profileToken: 'ptok').toConfigJson();
    final protected = await CredentialVault.protectConnectionConfig('tofa', config);
    for (final key in ['accessToken', 'refreshToken', 'profileToken']) {
      expect(CredentialVault.isProtected(protected[key] as String), isTrue, reason: key);
    }
    expect(protected['userName'], 'laura');
    expect(protected['connectUrl'], tofaCloud);
    final revealed = await CredentialVault.revealConnectionConfig('tofa', Map<String, dynamic>.from(protected));
    expect(revealed.config['accessToken'], 'acc-1');
    expect(revealed.config['refreshToken'], 'ref-1');
    expect(revealed.config['profileToken'], 'ptok');
  });

  group('registry', () {
    late AppDatabase db;
    late ConnectionRegistry registry;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      registry = ConnectionRegistry(db);
    });
    tearDown(() => db.close());

    test('a Tofa connection is stored and read back as one', () async {
      await registry.upsert(tofaConnection(profileToken: 'ptok'));
      final restored = await registry.get('srv-1/u-1/p-1');
      expect(restored, isA<TofaConnection>());
      expect((restored as TofaConnection).profileToken, 'ptok');
      final row = await db.select(db.connections).getSingle();
      expect(row.kind, 'tofa');
      expect(row.configJson, isNot(contains('acc-1')), reason: 'tokens are encrypted');
      expect(row.configJson, isNot(contains('ref-1')));
      expect(row.configJson, isNot(contains('ptok')));
    });

    test('a refreshed pair is stored only into a row of the same sign-in', () async {
      await registry.upsert(tofaConnection());
      final rotated = tofaConnection().copyWith(accessToken: 'acc-2', refreshToken: 'ref-2');
      expect(await registry.updateTofaSession(rotated, ownsRefreshToken: (t) => t == 'ref-1'), isTrue);
      expect(((await registry.get(rotated.id))! as TofaConnection).refreshToken, 'ref-2');

      // A new sign-in replaced the row: a late rotation of the old session is dropped.
      await registry.upsert(tofaConnection(accessToken: 'acc-9', refreshToken: 'ref-9'));
      final stale = tofaConnection().copyWith(accessToken: 'acc-3', refreshToken: 'ref-3');
      expect(await registry.updateTofaSession(stale, ownsRefreshToken: (t) => t == 'ref-2'), isFalse);
      expect(((await registry.get(rotated.id))! as TofaConnection).refreshToken, 'ref-9');
    });
  });

  test('the Tofa cache is registered, so forBackend never falls back to Plex', () {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    PlexApiCache.initialize(db);
    TofaApiCache.initialize(db);
    expect(ApiCache.forBackend(MediaBackend.tofa), isA<TofaApiCache>());
    expect(ApiCache.forBackend(MediaBackend.plex), isA<PlexApiCache>());
  });
}
