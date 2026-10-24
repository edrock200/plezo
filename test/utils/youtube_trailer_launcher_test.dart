import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/youtube_trailer_launcher.dart';

void main() {
  group('youtubeTrailerRouteFor', () {
    YoutubeTrailerRoute route(TargetPlatform platform, {bool tv = false, bool appleTv = false, bool car = false}) =>
        youtubeTrailerRouteFor(platform: platform, isTv: tv, isAppleTv: appleTv, isAutomotive: car);

    test('phones, tablets and macOS play in YouTube\'s embedded player', () {
      expect(route(TargetPlatform.android), YoutubeTrailerRoute.inAppPlayer);
      expect(route(TargetPlatform.iOS), YoutubeTrailerRoute.inAppPlayer);
      expect(route(TargetPlatform.macOS), YoutubeTrailerRoute.inAppPlayer);
    });

    test('Android TV and cars hand off to the YouTube app', () {
      expect(route(TargetPlatform.android, tv: true), YoutubeTrailerRoute.androidIntents);
      expect(route(TargetPlatform.android, car: true), YoutubeTrailerRoute.androidIntents);
    });

    test('Apple TV opens the YouTube app', () {
      expect(route(TargetPlatform.iOS, tv: true, appleTv: true), YoutubeTrailerRoute.appleTvApp);
    });

    test('Windows and Linux open the browser (no web view there)', () {
      expect(route(TargetPlatform.windows), YoutubeTrailerRoute.browser);
      expect(route(TargetPlatform.linux), YoutubeTrailerRoute.browser);
    });
  });

  group('youtubeAndroidIntents (Silo openYoutubeTrailer order)', () {
    test('a TV tries the YouTube TV app with the watch page first', () {
      expect(youtubeAndroidIntents('abc', isTv: true), const [
        AndroidViewIntent('https://www.youtube.com/watch?v=abc', package: youtubeTvPackage),
        AndroidViewIntent('vnd.youtube:abc'),
        AndroidViewIntent('https://www.youtube.com/watch?v=abc'),
      ]);
    });

    test('a phone tries the YouTube app link, then the watch page', () {
      expect(youtubeAndroidIntents('abc', isTv: false), const [
        AndroidViewIntent('vnd.youtube:abc'),
        AndroidViewIntent('https://www.youtube.com/watch?v=abc'),
      ]);
    });

    test('channel arguments carry url and package', () {
      expect(const AndroidViewIntent('vnd.youtube:abc').toMap(), {'url': 'vnd.youtube:abc', 'package': null});
    });
  });

  test('video ids are encoded into URLs', () {
    expect(youtubeWatchUrl('a&b'), 'https://www.youtube.com/watch?v=a%26b');
    expect(youtubeAppleTvUrl('abc'), 'youtube://watch/abc');
  });
}
