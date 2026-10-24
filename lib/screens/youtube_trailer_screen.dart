import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/remote_trailer.dart';
import '../utils/youtube_trailer_launcher.dart';
import '../widgets/app_icon.dart';

/// Full-screen route that plays a YouTube trailer with YouTube's official,
/// unmodified IFrame player (controls, branding and links stay YouTube's).
///
/// Only reached where [youtubeTrailerRouteFor] picks the in-app player
/// (Android phones/tablets, iOS, macOS): the web view it needs does not exist
/// on Windows, Linux or tvOS, so the controller is built in [State.initState]
/// and never on those platforms.
///
/// When YouTube refuses the video here (embedding disabled, 101/150/152,
/// or any other player error) the trailer is handed to the YouTube app or
/// the browser and the route closes.
class YoutubeTrailerScreen extends StatefulWidget {
  final RemoteTrailer trailer;

  const YoutubeTrailerScreen({super.key, required this.trailer});

  /// The page the player is loaded from. YouTube needs a real origin and
  /// referrer for embeds (errors 152/153 otherwise); with privacy-enhanced
  /// mode the player is served from this host, so it is also the origin.
  static const embedOrigin = 'https://www.youtube-nocookie.com';

  @override
  State<YoutubeTrailerScreen> createState() => _YoutubeTrailerScreenState();
}

class _YoutubeTrailerScreenState extends State<YoutubeTrailerScreen> {
  late final YoutubePlayerController _controller;
  StreamSubscription<YoutubePlayerValue>? _valueSub;
  final _closeFocusNode = FocusNode(debugLabel: 'youtube_trailer_close');
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.trailer.key,
      autoPlay: true,
      params: const YoutubePlayerParams(
        origin: YoutubeTrailerScreen.embedOrigin,
        strictRelatedVideos: true,
        showFullscreenButton: false,
      ),
    );
    _valueSub = _controller.stream.listen(_onValue);
  }

  void _onValue(YoutubePlayerValue value) {
    if (!value.hasError || _handedOff) return;
    _handedOff = true;
    unawaited(_handOff());
  }

  Future<void> _handOff() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(t.discover.youtubeTrailerPlaybackFailed)));
    final opened = await openYoutubeTrailerExternally(widget.trailer.key);
    if (!mounted) return;
    if (opened) {
      Navigator.of(context).maybePop();
    } else {
      messenger?.showSnackBar(SnackBar(content: Text(t.discover.youtubeTrailerOpenFailed)));
    }
  }

  void _close() => Navigator.of(context).maybePop();

  /// Back/Escape closes the route from anywhere in it (the shared helper
  /// fires on key up and swallows the matching down).
  KeyEventResult _onKey(FocusNode _, KeyEvent event) => handleBackKeyAction(event, _close);

  @override
  void dispose() {
    unawaited(_valueSub?.cancel());
    unawaited(_controller.close());
    _closeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.trailer.name ?? extraKindLabel(widget.trailer.kind);
    return Focus(
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          // The bar sits above the player, never over it: YouTube's embed
          // terms forbid covering the player.
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    FocusableButton(
                      focusNode: _closeFocusNode,
                      autofocus: true,
                      onPressed: _close,
                      child: IconButton(
                        onPressed: _close,
                        tooltip: t.common.close,
                        color: Colors.white,
                        icon: const AppIcon(Symbols.close_rounded, fill: 1),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    FocusableButton(
                      onPressed: () => unawaited(openYoutubeTrailerExternally(widget.trailer.key)),
                      child: TextButton(
                        onPressed: () => unawaited(openYoutubeTrailerExternally(widget.trailer.key)),
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        child: Text(t.discover.openInYoutube),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: YoutubePlayer(
                    controller: _controller,
                    backgroundColor: Colors.black,
                    autoFullScreen: false,
                    enableFullScreenOnVerticalDrag: false,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
