/// When the Play Next prompt opens before a Silo episode ends (Silo Android
/// #994, Silo's `NextUpPrompt`): the profile's Show Next Up setting
/// (`playback.next_up_prompt_seconds`, 0 = "At end", default 30) before the
/// end of the file, not at the credits marker. Credits markers still drive
/// Skip Credits.
abstract final class SiloNextUpPrompt {
  /// The Silo setting behind Show Next Up.
  static const settingKey = 'playback.next_up_prompt_seconds';

  /// The default of Silo's settings store and server.
  static const defaultSeconds = 30;

  /// The largest step between two position ticks that still counts as
  /// playback rather than a seek, so seeking or resuming past the point does
  /// not open the prompt.
  static const maxPlaybackStep = Duration(seconds: 3);

  /// The setting's value in a `GET /settings/values/effective` answer
  /// (`{items: [{key, value, source}]}`), whatever layer it comes from, or
  /// null when the answer does not name a usable one.
  static int? secondsFromEffective(Map<String, dynamic>? body) {
    final items = body?['items'];
    if (items is! List) return null;
    for (final item in items.whereType<Map>()) {
      if (item['key'] != settingKey) continue;
      final value = item['value'];
      final seconds = switch (value) {
        final num n when n.isFinite => n.round(),
        final String s => int.tryParse(s.trim()),
        _ => null,
      };
      if (seconds != null && seconds >= 0) return seconds;
    }
    return null;
  }

  /// Whether playback moved from [previous] to [position] across the point
  /// [promptSeconds] before [duration]. Only a forward playback step counts
  /// ([maxPlaybackStep]); 0 ("At end") or an unknown duration never opens the
  /// prompt early, which then waits for the stream to end.
  static bool crossesPromptPoint({
    required Duration previous,
    required Duration position,
    required Duration duration,
    required int promptSeconds,
  }) {
    if (promptSeconds <= 0 || duration <= Duration.zero) return false;
    final step = position - previous;
    if (step <= Duration.zero || step > maxPlaybackStep) return false;
    final promptStart = duration - Duration(seconds: promptSeconds);
    return previous < promptStart && position >= promptStart;
  }

  /// The countdown an early prompt shows: the playback time left, so it
  /// freezes on pause and grows on a backward seek (Silo's apps advance only
  /// when the stream ends).
  static int countdownSeconds({required Duration position, required Duration duration}) {
    final left = duration - position;
    if (left <= Duration.zero) return 0;
    return (left.inMilliseconds / 1000).ceil();
  }
}
