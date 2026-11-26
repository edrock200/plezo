import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/models/tofa_subtitle_tools.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/tofa/tofa_subtitle_search_sheet.dart';

import '../../services/tofa/tofa_fixtures.dart';
import '../../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTofa fake;
  late AppDatabase db;
  var subtitleTracks = <Map<String, Object?>>[];

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    fake = FakeTofa();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    TofaApiCache.initialize(db);
    subtitleTracks = [
      {'index': 0, 'codec': 'subrip', 'language': 'eng', 'forced': false, 'title': null},
    ];
    fake.on('GET', '/api/v1/media/m-1', (_) => jsonResponse(movieDetail()));
    fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
    fake.on('GET', '/api/v1/stream/f-1/info', (_) => jsonResponse(playbackInfo()));
    fake.on('GET', '/api/v1/stream/f-1/subtitles', (_) => jsonResponse(subtitleTracks));
    fake.on(
      'GET',
      '/api/v1/subtitles/fetch/files/f-1/candidates',
      (r) => jsonResponse({
        'cached': false,
        'can_fetch': true,
        'degraded': false,
        'file_fps': null,
        'selected_candidate': null,
        'candidates': [
          {
            'id': 'c-1',
            'language': r.url.queryParameters['language'],
            'provider': 'opensubtitles',
            'release': 'Movie.2021.1080p',
            'score': 97,
            'hash_match': true,
            'hearing_impaired': false,
            'forced': false,
            'trusted': true,
            'rejected': false,
            'deferred': false,
            'downloads': 10,
            'fps': null,
            'metered': false,
          },
          {
            'id': 'c-2',
            'language': 'en',
            'provider': 'x',
            'release': 'Rejected one',
            'score': 1,
            'hash_match': false,
            'hearing_impaired': false,
            'forced': false,
            'trusted': false,
            'rejected': true,
            'deferred': false,
            'downloads': 0,
            'fps': null,
            'metered': false,
          },
        ],
      }),
    );
    fake.on('POST', '/api/v1/subtitles/fetch/files/f-1/candidate', (r) {
      expect(jsonDecode(r.body), {'candidate_id': 'c-1', 'language': 'en'});
      subtitleTracks = [
        ...subtitleTracks,
        {'index': 1, 'codec': 'subrip', 'language': 'eng', 'forced': false, 'title': 'Fetched', 'external': true},
      ];
      return jsonResponse(const {}, 202);
    });
  });
  tearDown(() => db.close());

  testWidgets('searching, picking a candidate and selecting the fetched track', (tester) async {
    final client = TofaClient.forTesting(
      tofaConnection(),
      headers: const TofaClientHeaders(clientVersion: '1.0', platform: 'android', deviceName: 'Test device'),
      httpClient: fake.client,
    )..raceWait = (_) async {};
    await tester.runAsync(() async {
      final movie = await client.fetchItem('m-1');
      await client.getPlaybackInitialization(PlaybackInitializationOptions(metadata: movie!, selectedMediaIndex: 0));
    });
    expect(client.playingFileId('m-1'), 'f-1');
    int? applied;
    final tools = TofaSubtitleTools(
      client: client,
      itemId: 'm-1',
      applyTrack: (index) async {
        applied = index;
        return SubtitleDownloadApplyOutcome.applied;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: OverlaySheetHost(
          child: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => OverlaySheetController.of(
                  context,
                ).show<void>(builder: (_) => TofaSubtitleSearchSheet(tools: tools)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Movie.2021.1080p'), findsOneWidget);
    expect(find.text('Rejected one'), findsNothing);
    await tester.tap(find.text('Movie.2021.1080p'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(applied, 1, reason: 'the new track index, selected through a reload');
  });
}
