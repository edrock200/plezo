import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/transport_keys.dart';

void main() {
  test('only the Stop key leaves the player', () {
    expect(isPlayerStopKey(LogicalKeyboardKey.mediaStop), isTrue);
    expect(isPlayerStopKey(LogicalKeyboardKey.mediaPause), isFalse);
    expect(isPlayerStopKey(LogicalKeyboardKey.mediaPlayPause), isFalse);
    expect(isPlayerStopKey(LogicalKeyboardKey.escape), isFalse);
  });

  test('Stop is not a transport toggle', () {
    expect(classifyTransportKey(LogicalKeyboardKey.mediaStop), isNull);
  });
}
