import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import 'app_logger.dart';
import 'platform_detector.dart';

class TextInputDiagnostics {
  /// Compile-time switch: run with
  /// `--dart-define=PLEZY_TEXT_INPUT_DIAGNOSTICS=true` to enable.
  static const bool _compiledIn = bool.fromEnvironment('PLEZY_TEXT_INPUT_DIAGNOSTICS');

  static bool _platformEnabled = false;

  /// On in a release build too once Android reports
  /// `adb shell setprop log.tag.PleziloTextInput DEBUG` (read by PlezyActivity at
  /// start; see [loadPlatformSetting]). Lines go to logcat tag `flutter`.
  static bool get enabled => _compiledIn || _platformEnabled;

  /// Asks PlezyActivity whether text-input diagnostics were switched on with
  /// adb, so one logcat capture shows both the IME's InputConnection calls
  /// (tag `PleziloTextInput`) and what the Flutter field did with them.
  static Future<void> loadPlatformSetting() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _platformEnabled =
          await const MethodChannel('com.plezy/text_input').invokeMethod<bool>('isDiagnosticsEnabled') ?? false;
    } on MissingPluginException {
      // Older activity or tests: stay off.
    } on PlatformException {
      // Best effort.
    }
    if (_platformEnabled) appLogger.i('TextInputDiag diagnostics enabled from log.tag.PleziloTextInput');
  }

  @visibleForTesting
  static void debugReset() => _platformEnabled = false;

  static void log(String source, String message) {
    if (!enabled || !PlatformDetector.isTV()) return;
    appLogger.i('TextInputDiag $source: $message');
  }
}
