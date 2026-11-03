import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../focus/focusable_button.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/remote_trailer.dart';
import '../utils/platform_detector.dart';
import '../utils/youtube_trailer_launcher.dart';
import '../widgets/app_icon.dart';

/// Full-screen route that plays a YouTube trailer with YouTube's official,
/// unmodified IFrame player (controls, branding and links stay YouTube's).
///
/// Only reached where [youtubeTrailerRouteFor] picks the in-app player
/// (Android phones/tablets, Android TV/Fire TV, iOS, macOS): the web view it
/// needs does not exist on Windows, Linux or tvOS, so the controller is built
/// in [State.initState] and never on those platforms.
///
/// On a TV the D-pad cannot drive YouTube's page, so the bar above the player
/// adds Back 10 s, Play/Pause and Forward 10 s buttons, the remote's media
/// keys work anywhere on the screen, and the web view never takes focus.
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
  final _playPauseFocusNode = FocusNode(debugLabel: 'youtube_trailer_play_pause');
  late final bool _isTv = PlatformDetector.isTV();
  bool _handedOff = false;
  bool _playing = false;

  static const _seekStepSeconds = 10;

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
    final playing = value.playerState == PlayerState.playing || value.playerState == PlayerState.buffering;
    if (playing != _playing && mounted) setState(() => _playing = playing);
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

  void _togglePlay() => unawaited(_playing ? _controller.pauseVideo() : _controller.playVideo());

  Future<void> _seekBy(int seconds) async {
    try {
      final now = await _controller.currentTime;
      final duration = _controller.metadata.duration.inSeconds;
      var target = now + seconds;
      if (target < 0) target = 0;
      if (duration > 0 && target > duration - 1) target = (duration - 1).toDouble();
      await _controller.seekTo(seconds: target, allowSeekAhead: true);
    } catch (_) {
      // The player is not ready yet; the press does nothing.
    }
  }

  /// Back/Escape closes the route from anywhere in it (the shared helper
  /// fires on key up and swallows the matching down). The remote's media
  /// keys drive the player.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final media = switch (key) {
      LogicalKeyboardKey.mediaPlayPause => _togglePlay,
      LogicalKeyboardKey.mediaPlay => () => unawaited(_controller.playVideo()),
      LogicalKeyboardKey.mediaPause || LogicalKeyboardKey.mediaStop => () => unawaited(_controller.pauseVideo()),
      LogicalKeyboardKey.mediaRewind => () => unawaited(_seekBy(-_seekStepSeconds)),
      LogicalKeyboardKey.mediaFastForward => () => unawaited(_seekBy(_seekStepSeconds)),
      _ => null,
    };
    if (media != null) {
      if (event is KeyDownEvent || (event is KeyRepeatEvent && key != LogicalKeyboardKey.mediaPlayPause)) media();
      return KeyEventResult.handled;
    }
    return handleBackKeyAction(event, _close);
  }

  Widget _transportButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    FocusNode? focusNode,
    bool autofocus = false,
  }) => FocusableButton(
    focusNode: focusNode,
    autofocus: autofocus,
    onPressed: onPressed,
    child: IconButton(onPressed: onPressed, tooltip: tooltip, color: Colors.white, icon: AppIcon(icon, fill: 1)),
  );

  @override
  void dispose() {
    unawaited(_valueSub?.cancel());
    unawaited(_controller.close());
    _closeFocusNode.dispose();
    _playPauseFocusNode.dispose();
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
                      autofocus: !_isTv,
                      onPressed: _close,
                      child: IconButton(
                        onPressed: _close,
                        tooltip: t.common.close,
                        color: Colors.white,
                        icon: const AppIcon(Symbols.close_rounded, fill: 1),
                      ),
                    ),
                    if (_isTv) ...[
                      const SizedBox(width: 8),
                      _transportButton(
                        icon: Symbols.replay_10_rounded,
                        tooltip: t.videoControls.seekBackwardButton(seconds: _seekStepSeconds),
                        onPressed: () => unawaited(_seekBy(-_seekStepSeconds)),
                      ),
                      _transportButton(
                        focusNode: _playPauseFocusNode,
                        autofocus: true,
                        icon: _playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                        tooltip: _playing ? t.videoControls.pauseButton : t.videoControls.playButton,
                        onPressed: _togglePlay,
                      ),
                      _transportButton(
                        icon: Symbols.forward_10_rounded,
                        tooltip: t.videoControls.seekForwardButton(seconds: _seekStepSeconds),
                        onPressed: () => unawaited(_seekBy(_seekStepSeconds)),
                      ),
                    ],
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
                  // On a TV the web view must never hold focus: the remote
                  // could not leave YouTube's page again.
                  child: ExcludeFocus(
                    excluding: _isTv,
                    child: YoutubePlayer(
                      controller: _controller,
                      backgroundColor: Colors.black,
                      autoFullScreen: false,
                      enableFullScreenOnVerticalDrag: false,
                    ),
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
