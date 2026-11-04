import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/silo_accounts.dart';

SiloConnection _silo({
  String serverId = 'srv-1',
  String userId = 'u-laura',
  String userName = 'laura',
  String profileId = 'p-1',
  String profileName = 'Laura',
}) => SiloConnection(
  id: SiloConnection.compoundId(serverId: serverId, userId: userId, profileId: profileId),
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: serverId,
  userId: userId,
  userName: userName,
  accessToken: 'acc-$userId',
  refreshToken: 'ref-$userId',
  deviceId: 'dev-1',
  profileId: profileId,
  profileName: profileName,
  createdAt: DateTime(2026),
);

ProfileConnection _row(Connection c, {bool isDefault = false, DateTime? lastUsedAt, String profileId = 'local-1'}) =>
    ProfileConnection(
      profileId: profileId,
      connectionId: c.id,
      userIdentifier: '',
      isDefault: isDefault,
      lastUsedAt: lastUsedAt,
    );

void main() {
  final laura = _silo();
  final sam = _silo(userId: 'u-sam', userName: 'sam', profileName: 'Sam');
  final elsewhere = _silo(serverId: 'srv-2', userId: 'u-sam', userName: 'sam', profileName: 'Sam');
  final byId = {
    for (final c in [laura, sam, elsewhere]) c.id: c,
  };

  group('otherSiloConnectionOnServer', () {
    test('finds another account on the same server', () {
      expect(otherSiloConnectionOnServer(incoming: sam, joinRows: [_row(laura)], connectionsById: byId), laura);
    });

    test('the same account (same server user id and profile) is not another one', () {
      final readded = _silo().copyWith(accessToken: 'acc-new', refreshToken: 'ref-new');
      expect(readded.id, laura.id);
      expect(otherSiloConnectionOnServer(incoming: readded, joinRows: [_row(laura)], connectionsById: byId), isNull);
    });

    test('an account on another server does not count', () {
      expect(otherSiloConnectionOnServer(incoming: sam, joinRows: [_row(elsewhere)], connectionsById: byId), isNull);
    });
  });

  group('shadowedSiloConnectionIds', () {
    test('one account per server: the default binding wins', () {
      expect(shadowedSiloConnectionIds([_row(sam), _row(laura, isDefault: true)], byId), {sam.id});
    });

    test('then the most recently used, then the lowest id', () {
      expect(
        shadowedSiloConnectionIds([
          _row(laura, lastUsedAt: DateTime(2026, 1)),
          _row(sam, lastUsedAt: DateTime(2026, 2)),
        ], byId),
        {laura.id},
      );
      expect(shadowedSiloConnectionIds([_row(sam), _row(laura)], byId), {
        sam.id,
      }, reason: 'srv-1/u-laura < srv-1/u-sam');
    });

    test('accounts on different servers are all bound', () {
      expect(shadowedSiloConnectionIds([_row(laura), _row(elsewhere)], byId), isEmpty);
    });
  });

  test('siloAccountLabel names the Silo profile and, when different, the username', () {
    expect(siloAccountLabel(laura), 'Laura (laura)');
    expect(siloAccountLabel(_silo(profileName: 'laura')), 'laura');
    expect(siloAccountLabel(_silo(profileName: '')), 'laura');
  });

  test('newProfileNameForSiloConnection avoids names already in use', () {
    expect(newProfileNameForSiloConnection(sam, ['Laura']), 'Sam');
    expect(newProfileNameForSiloConnection(sam, ['sam']), 'Sam (sam)');
    expect(newProfileNameForSiloConnection(sam, ['Sam', 'Sam (sam)']), 'Sam · Home Silo');
    expect(
      newProfileNameForSiloConnection(sam, ['Sam', 'Sam (sam)', 'Sam · Home Silo', 'Sam (sam) · Home Silo']),
      'Sam 2',
    );
  });
}
