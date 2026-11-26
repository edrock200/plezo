import 'dart:io';

import '../../connection/connection.dart';
import '../../utils/app_logger.dart';
import 'iptv_recorder.dart';
import 'iptv_store.dart';

/// Removes everything the device holds for a removed IPTV source: its
/// channels, guide, movies and series, favourites, channel changes, watch
/// progress, reminders, recordings (files too) and a copied playlist file.
class IptvSourceCleanup {
  IptvSourceCleanup._();

  static Future<void> remove(IptvConnection connection) async {
    if (!IptvStore.isInitialized) return;
    try {
      await IptvRecorder.instance.deleteSource(connection.id);
    } catch (e) {
      appLogger.w('[iptv] recordings of a removed source not deleted (${e.runtimeType})');
    }
    await IptvStore.instance.deleteSource(connection.id);
    final file = connection.m3uFilePath;
    if (file != null) {
      try {
        final copy = File(file);
        if (await copy.exists()) await copy.delete();
      } catch (e) {
        appLogger.w('[iptv] playlist copy not deleted (${e.runtimeType})');
      }
    }
  }
}
