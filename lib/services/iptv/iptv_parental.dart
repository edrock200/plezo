import 'package:flutter/foundation.dart';

/// The parental filter's state for this run of the app: which sources have
/// their locked groups shown. Locked groups are hidden again on a restart
/// and on every profile switch ([lockAll]).
class IptvParentalGate {
  IptvParentalGate._();

  static final Set<String> _unlocked = {};

  /// Bumped on every change, so open screens re-read their channels.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static bool isUnlocked(String sourceId) => _unlocked.contains(sourceId);

  static void unlock(String sourceId) {
    if (_unlocked.add(sourceId)) revision.value++;
  }

  static void lock(String sourceId) {
    if (_unlocked.remove(sourceId)) revision.value++;
  }

  static void lockAll() {
    if (_unlocked.isEmpty) return;
    _unlocked.clear();
    revision.value++;
  }
}
