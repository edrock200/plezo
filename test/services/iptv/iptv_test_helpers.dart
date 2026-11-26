import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drift/native.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/iptv/iptv_api_cache.dart';
import 'package:plezy/services/iptv/iptv_store.dart';

import 'fake_iptv_server.dart';

/// A fresh in-memory IPTV database, installed as the app's store.
IptvStore memoryIptvStore() {
  final store = IptvStore(IptvDatabase(NativeDatabase.memory()));
  IptvStore.testInstance = store;
  return store;
}

/// Installs [IptvApiCache] over an in-memory app database.
AppDatabase memoryAppDatabaseWithIptvCache() {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  IptvApiCache.initialize(db);
  return db;
}

IptvConnection m3uSource(String base, {String id = 'iptv-test-m3u', List<String> epgUrls = const [], int shift = 0}) =>
    IptvConnection(
      id: id,
      sourceType: IptvSourceType.m3u,
      name: 'Test playlist',
      m3uUrl: '$base/playlist.m3u',
      epgUrls: epgUrls,
      epgShiftMinutes: shift,
      createdAt: DateTime(2026),
    );

IptvConnection xtreamSource(
  String base, {
  String id = 'iptv-test-xc',
  String password = 'secret',
  bool includeVod = true,
}) => IptvConnection(
  id: id,
  sourceType: IptvSourceType.xtream,
  name: 'Test Xtream',
  xtreamServer: base,
  xtreamUsername: 'demo',
  xtreamPassword: password,
  includeVod: includeVod,
  createdAt: DateTime(2026),
);

/// An HTTP client answered by [server] in process (no socket), for widget
/// tests, where real sockets are blocked.
http.Client fakeIptvHttpClient(FakeIptvServer server) => MockClient.streaming((request, _) async {
  final answer = server.respond(request.url);
  return http.StreamedResponse(Stream.value(answer.body), answer.status, headers: {'content-type': answer.type});
});
