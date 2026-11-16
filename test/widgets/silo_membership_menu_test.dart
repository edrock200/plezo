import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_memberships.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/media_context_menu.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/profile_stack.dart';

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

MediaItem _card(MediaKind kind, {Map<String, dynamic>? userState}) => MediaItem.silo(
  id: 'movie:m1',
  kind: kind,
  title: 'Heat',
  serverId: 'srv-1',
  raw: {'content_id': 'movie:m1', 'user_state': ?userState},
);

/// Siku's card menu (HomeCardActions.brs): Silo movie and show cards offer
/// Add to / Remove from Watchlist and Favorites.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> writes;
  late SiloClient client;

  Future<GlobalKey<MediaContextMenuState>> pumpMenu(WidgetTester tester, MediaItem item) async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    writes = [];
    client = SiloClient.forTesting(
      _connection(),
      headers: _headers,
      httpClient: MockClient((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.startsWith('/api/v2/watchlist/') || path.startsWith('/api/v2/favorites/')) {
          writes.add('${request.method} $path');
          return http.Response('', 204);
        }
        return http.Response(jsonEncode({}), 404, headers: {'content-type': 'application/json'});
      }),
    );
    final manager = MultiServerManager()..debugRegisterClientForTesting(client, online: true);
    final multiServerProvider = testMultiServerProvider(manager);
    final offlineMode = OfflineModeProvider(manager);
    final stack = await ProfileStack.create(withStorage: false);
    addTearDown(() async {
      await stack.dispose();
      offlineMode.dispose();
      multiServerProvider.dispose();
      manager.dispose();
    });
    final menuKey = GlobalKey<MediaContextMenuState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: stack.active),
            ChangeNotifierProvider<OfflineModeProvider>.value(value: offlineMode),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: Center(
                child: MediaContextMenu(
                  key: menuKey,
                  item: item,
                  child: const SizedBox(width: 120, height: 80, child: Text('card')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return menuKey;
  }

  Future<void> open(WidgetTester tester, GlobalKey<MediaContextMenuState> key) async {
    key.currentState!.showContextMenu(tester.element(find.text('card')));
    await tester.pumpAndSettle();
  }

  testWidgets('a Silo movie card offers Add to Watchlist and Add to Favorites, and the pick writes it', (tester) async {
    final key = await pumpMenu(tester, _card(MediaKind.movie));
    await open(tester, key);

    expect(find.text(t.explore.addToWatchlist), findsOneWidget);
    expect(find.text(t.siloMemberships.addToFavorites), findsOneWidget);

    await tester.tap(find.text(t.explore.addToWatchlist));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(writes, ['PUT /api/v2/watchlist/movie:m1']);
    expect(client.memberships.isMember(_card(MediaKind.movie), SiloMembership.watchlist), isTrue);

    await open(tester, key);
    expect(find.text(t.explore.removeFromWatchlist), findsOneWidget, reason: "the menu follows the session's press");
  });

  testWidgets('a show already on both lists offers the removals', (tester) async {
    final key = await pumpMenu(tester, _card(MediaKind.show, userState: {'in_watchlist': true, 'is_favorite': true}));
    await open(tester, key);

    expect(find.text(t.explore.removeFromWatchlist), findsOneWidget);
    expect(find.text(t.siloMemberships.removeFromFavorites), findsOneWidget);
  });

  testWidgets('an episode card has neither', (tester) async {
    final key = await pumpMenu(tester, _card(MediaKind.episode));
    await open(tester, key);

    expect(find.text(t.explore.addToWatchlist), findsNothing);
    expect(find.text(t.siloMemberships.addToFavorites), findsNothing);
  });
}
