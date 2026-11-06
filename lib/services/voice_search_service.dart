import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';

/// What one voice search ended in.
sealed class VoiceSearchOutcome {
  const VoiceSearchOutcome();
}

/// The recogniser's top result, trimmed and never empty.
final class VoiceSearchText extends VoiceSearchOutcome {
  const VoiceSearchText(this.text);
  final String text;
}

/// The viewer backed out, or nothing was understood: the query stays as it was.
final class VoiceSearchCancelled extends VoiceSearchOutcome {
  const VoiceSearchCancelled();
}

/// No recogniser could take the request (uninstalled or disabled since the
/// button was shown).
final class VoiceSearchUnavailable extends VoiceSearchOutcome {
  const VoiceSearchUnavailable();
}

/// Voice search on Android TV and Fire TV through the system speech
/// recogniser (`com.plezy/voice_search`, `VoiceSearchChannel.kt`; port of
/// Silo Android #830). The recogniser listens in its own app through the
/// remote's microphone, so Plezilo records nothing and needs no RECORD_AUDIO
/// for it. Other platforms never show the button.
class VoiceSearchService {
  VoiceSearchService({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('com.plezy/voice_search');

  static VoiceSearchService instance = VoiceSearchService();

  final MethodChannel _channel;
  Future<bool>? _available;

  /// Android TV hardware only (the force-TV layout on a phone or tablet keeps
  /// the phone's own keyboard mic).
  bool get platformSupported =>
      (debugIsAndroid ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)) && PlatformDetector.isTVDevice();

  /// Tests stand in for Android.
  @visibleForTesting
  bool? debugIsAndroid;

  /// Whether a recogniser is installed; read once per process (installing one
  /// mid-session is not worth re-querying for). False off Android TV.
  Future<bool> isAvailable() {
    if (!platformSupported) return Future.value(false);
    return _available ??= () async {
      try {
        return await _channel.invokeMethod<bool>('isAvailable') ?? false;
      } on PlatformException catch (e) {
        appLogger.d('Voice search: availability check failed', error: e.code);
        return false;
      } on MissingPluginException {
        return false;
      }
    }();
  }

  /// Hands listening to the recogniser and returns its top result.
  Future<VoiceSearchOutcome> listen({required String prompt}) async {
    try {
      final answer = await _channel.invokeMapMethod<String, dynamic>('recognize', {'prompt': prompt});
      final text = answer?['text'];
      return switch (answer?['status']) {
        'ok' when text is String && text.trim().isNotEmpty => VoiceSearchText(text.trim()),
        'unavailable' => const VoiceSearchUnavailable(),
        _ => const VoiceSearchCancelled(),
      };
    } on PlatformException catch (e) {
      appLogger.d('Voice search: recognise failed', error: e.code);
      // Already listening: the first press is still being answered.
      return e.code == 'ALREADY_ACTIVE' ? const VoiceSearchCancelled() : const VoiceSearchUnavailable();
    } on MissingPluginException {
      return const VoiceSearchUnavailable();
    }
  }
}
