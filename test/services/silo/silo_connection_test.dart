import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/credential_vault.dart';

import '../../test_helpers/prefs.dart';

SiloConnection _connection({String? profileToken}) => SiloConnection(
  id: SiloConnection.compoundId(serverId: 'srv-1', userId: '7', profileId: 'p-kids'),
  baseUrl: 'HTTPS://Silo.Example.com/prefix/',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '7',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  accessTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
  deviceId: 'dev-1',
  profileId: 'p-kids',
  profileName: 'Kids',
  profileAvatarUrl: 'https://silo.example.com/avatars/kids.png',
  profileToken: profileToken,
  profileHasPin: profileToken != null,
  isAdministrator: true,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('compound id names server, account and Silo profile', () {
    expect(_connection().id, 'srv-1/7/p-kids');
    expect(_connection().kind, MediaBackend.silo);
  });

  test('canonicalizes the base URL scheme and trailing slash', () {
    expect(_connection().baseUrl, 'https://Silo.Example.com/prefix');
  });

  test('config JSON round-trips every field', () {
    final original = _connection(profileToken: 'ptok');
    final restored = SiloConnection.fromConfigJson(
      id: original.id,
      json: original.toConfigJson(),
      createdAt: original.createdAt,
    );
    expect(restored.toConfigJson(), original.toConfigJson());
    expect(restored.accessTokenExpiresAt, original.accessTokenExpiresAt);
    expect(restored.profileToken, 'ptok');
  });

  test('an empty stored profile token reads back as none', () {
    final json = _connection().toConfigJson()..['profileToken'] = '';
    final restored = SiloConnection.fromConfigJson(id: 'x', json: json, createdAt: DateTime(2026));
    expect(restored.profileToken, isNull);
  });

  test('copyWith rotates tokens and keeps identity', () {
    final rotated = _connection(
      profileToken: 'ptok',
    ).copyWith(accessToken: 'acc-2', refreshToken: 'ref-2', clearProfileToken: true);
    expect(rotated.id, 'srv-1/7/p-kids');
    expect(rotated.accessToken, 'acc-2');
    expect(rotated.refreshToken, 'ref-2');
    expect(rotated.profileToken, isNull);
  });

  test('credential vault encrypts every Silo token at rest', () async {
    final config = _connection(profileToken: 'ptok').toConfigJson();
    final protected = await CredentialVault.protectConnectionConfig('silo', config);
    for (final key in ['accessToken', 'refreshToken', 'profileToken']) {
      expect(CredentialVault.isProtected(protected[key] as String), isTrue, reason: key);
    }
    expect(protected['userName'], 'laura');

    final revealed = await CredentialVault.revealConnectionConfig('silo', Map<String, dynamic>.from(protected));
    expect(revealed.config['accessToken'], 'acc-1');
    expect(revealed.config['refreshToken'], 'ref-1');
    expect(revealed.config['profileToken'], 'ptok');
  });
}
