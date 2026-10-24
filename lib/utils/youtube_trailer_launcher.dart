import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../media/remote_trailer.dart';
import '../screens/youtube_trailer_screen.dart';
import 'app_logger.dart';
import 'platform_detector.dart';
import 'snackbar_helper.dart';

/// How Plezy opens a YouTube trailer on this device.
enum YoutubeTrailerRoute {
  /// YouTube's official IFrame player in a full-screen route
  /// ([YoutubeTrailerScreen]). Phones, tablets and macOS.
  inAppPlayer,

  /// `ACTION_VIEW` intents handed to the YouTube app, then the browser
  /// (Android TV, and Android when the in-app player cannot play).
  androidIntents,

  /// The YouTube app's URL scheme through the tvOS Runner's own channel
  /// (tvOS has no url_launcher or web view).
  appleTvApp,

  /// The default browser through url_launcher (Windows, Linux: there is no
  /// web view for them).
  browser,
}

/// Pure route choice; [openYoutubeTrailer] passes the live platform.
YoutubeTrailerRoute youtubeTrailerRouteFor({
  required TargetPlatform platform,
  required bool isTv,
  required bool isAppleTv,
  bool isAutomotive = false,
}) {
  if (isAppleTv) return YoutubeTrailerRoute.appleTvApp;
  switch (platform) {
    case TargetPlatform.android:
      // No web view player on a TV (D-pad cannot drive YouTube's page) or in
      // a car: hand off to the YouTube app instead, as Silo's TV app does.
      return isTv || isAutomotive ? YoutubeTrailerRoute.androidIntents : YoutubeTrailerRoute.inAppPlayer;
    case TargetPlatform.iOS || TargetPlatform.macOS:
      return YoutubeTrailerRoute.inAppPlayer;
    case TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.fuchsia:
      return YoutubeTrailerRoute.browser;
  }
}

/// YouTube's TV app. It opens a `vnd.youtube:` link on its home screen
/// without starting the video, so a TV gives it the watch page first.
const youtubeTvPackage = 'com.google.android.youtube.tv';

/// One `ACTION_VIEW` attempt for the Android channel.
@immutable
class AndroidViewIntent {
  final String url;
  final String? package;
  const AndroidViewIntent(this.url, {this.package});

  Map<String, Object?> toMap() => {'url': url, 'package': package};

  @override
  bool operator ==(Object other) => other is AndroidViewIntent && other.url == url && other.package == package;

  @override
  int get hashCode => Object.hash(url, package);

  @override
  String toString() => 'AndroidViewIntent($url, $package)';
}

/// The intents Silo's Android apps try, in order (`openYoutubeTrailer`): on
/// a TV the YouTube TV app with the watch page; then any app for
/// `vnd.youtube:<id>` (the YouTube app); then the watch page in any app.
List<AndroidViewIntent> youtubeAndroidIntents(String videoId, {required bool isTv}) {
  final watchPage = youtubeWatchUrl(videoId);
  return [
    if (isTv) AndroidViewIntent(watchPage, package: youtubeTvPackage),
    AndroidViewIntent('vnd.youtube:${Uri.encodeComponent(videoId)}'),
    AndroidViewIntent(watchPage),
  ];
}

/// The public watch page of [videoId].
String youtubeWatchUrl(String videoId) => 'https://www.youtube.com/watch?v=${Uri.encodeQueryComponent(videoId)}';

/// The YouTube app's link on tvOS.
String youtubeAppleTvUrl(String videoId) => 'youtube://watch/${Uri.encodeComponent(videoId)}';

const _externalPlayerChannel = MethodChannel('com.plezy/external_player');

/// Open [trailer] the way this device supports. Never throws; tells the
/// user when nothing could open it.
Future<void> openYoutubeTrailer(BuildContext context, RemoteTrailer trailer) async {
  if (!trailer.isYoutube) return;
  final route = youtubeTrailerRouteFor(
    platform: defaultTargetPlatform,
    isTv: PlatformDetector.isTV(),
    isAppleTv: PlatformDetector.isAppleTV(),
    isAutomotive: PlatformDetector.isAutomotive(),
  );
  if (route == YoutubeTrailerRoute.inAppPlayer) {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => YoutubeTrailerScreen(trailer: trailer)));
    return;
  }
  final opened = await openYoutubeTrailerExternally(trailer.key, route: route);
  if (!opened && context.mounted) showErrorSnackBar(context, t.discover.youtubeTrailerOpenFailed);
}

/// Hand [videoId] to the YouTube app or a browser. [route] defaults to this
/// platform's external route (the in-app player's fallback). True when
/// something opened it.
Future<bool> openYoutubeTrailerExternally(String videoId, {YoutubeTrailerRoute? route}) async {
  final target =
      route ??
      switch (defaultTargetPlatform) {
        TargetPlatform.android => YoutubeTrailerRoute.androidIntents,
        _ => PlatformDetector.isAppleTV() ? YoutubeTrailerRoute.appleTvApp : YoutubeTrailerRoute.browser,
      };
  try {
    switch (target) {
      case YoutubeTrailerRoute.androidIntents:
        final intents = youtubeAndroidIntents(videoId, isTv: PlatformDetector.isTV());
        return await _externalPlayerChannel.invokeMethod<bool>('openViewIntents', {
              'targets': [for (final intent in intents) intent.toMap()],
            }) ??
            false;
      case YoutubeTrailerRoute.appleTvApp:
        return await _externalPlayerChannel.invokeMethod<bool>('openUrl', {'url': youtubeAppleTvUrl(videoId)}) ?? false;
      case YoutubeTrailerRoute.browser || YoutubeTrailerRoute.inAppPlayer:
        return await launchUrl(Uri.parse(youtubeWatchUrl(videoId)), mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    appLogger.w('Could not open YouTube trailer', error: e);
    return false;
  }
}
