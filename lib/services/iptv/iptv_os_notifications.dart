import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import 'iptv_store.dart';

/// Shows reminders in the system notification area.
abstract interface class IptvReminderNotifier {
  /// Whether [schedule] hands the reminder to the system, which shows it even
  /// while Plezilo is closed (Android, iOS, macOS, Windows). Where it cannot
  /// (Linux), the app shows it with [showNow] when it is due.
  bool get schedulesAhead;

  /// Ask the system to show [reminder] at [at]. False when it refused
  /// (no permission, unsupported): the in-app dialog is the fallback.
  Future<bool> schedule(IptvReminder reminder, DateTime at);

  Future<void> cancel(IptvReminder reminder);

  /// Show [reminder] now. False when it could not.
  Future<bool> showNow(IptvReminder reminder);
}

/// [IptvReminderNotifier] over flutter_local_notifications (BSD-3-Clause).
///
/// Not used on TV (Android TV shows no notification shade; Plezilo's tvOS
/// build has no notification plugin), where the in-app dialog stays.
/// Selecting a notification opens the channel ([onOpen]); a notification
/// that launched the app is delivered once [onOpen] is set.
class IptvOsNotifications implements IptvReminderNotifier {
  IptvOsNotifications._();

  static IptvOsNotifications? _instance;

  /// Null where system notifications are not used (TV, web, tests).
  static IptvOsNotifications? get instance => _instance;

  /// Whether this platform gets system notifications for reminders.
  static bool get platformSupported {
    if (kIsWeb || PlatformDetector.isTV()) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _permissionAsked = false;
  bool _permitted = true;
  IptvReminder? _pendingOpen;
  void Function(IptvReminder reminder)? _onOpen;

  /// Selecting a notification opens its channel.
  set onOpen(void Function(IptvReminder reminder)? handler) {
    _onOpen = handler;
    final pending = _pendingOpen;
    if (handler != null && pending != null) {
      _pendingOpen = null;
      handler(pending);
    }
  }

  static const _windowsGuid = 'b7f3c2a8-4d1e-4c6b-9a5f-2e8d7c1b3a90';

  /// Set the plugin up; returns null where it cannot be used.
  static Future<IptvOsNotifications?> initialize() async {
    if (!platformSupported) return null;
    final notifications = IptvOsNotifications._();
    try {
      final ok = await notifications._plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_notification'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'Plezilo',
            appUserModelId: 'com.edrock200.plezilo',
            guid: _windowsGuid,
          ),
        ),
        onDidReceiveNotificationResponse: (response) => notifications._opened(response.payload),
      );
      if (ok == false) return null;
      final launch = await notifications._plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) notifications._opened(launch?.notificationResponse?.payload);
      _instance = notifications;
      appLogger.i('[iptv] system notifications ready for reminders');
      return notifications;
    } catch (e) {
      appLogger.w('[iptv] system notifications unavailable (${e.runtimeType}); reminders stay in the app');
      return null;
    }
  }

  void _opened(String? payload) {
    final reminder = payloadToReminder(payload);
    if (reminder == null) return;
    final handler = _onOpen;
    if (handler == null) {
      _pendingOpen = reminder;
    } else {
      handler(reminder);
    }
  }

  @visibleForTesting
  static String reminderPayload(IptvReminder r) =>
      jsonEncode({'s': r.sourceId, 'c': r.channelId, 'st': r.start, 'sp': r.stop, 't': r.title, 'n': r.channelName});

  @visibleForTesting
  static IptvReminder? payloadToReminder(String? payload) {
    if (payload == null) return null;
    try {
      final m = jsonDecode(payload);
      if (m is! Map || m['s'] is! String || m['c'] is! String || m['st'] is! int) return null;
      return IptvReminder(
        sourceId: m['s'] as String,
        channelId: m['c'] as String,
        start: m['st'] as int,
        stop: m['sp'] is int ? m['sp'] as int : (m['st'] as int) + 3600,
        title: m['t'] is String ? m['t'] as String : '',
        channelName: m['n'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// A stable notification id for a reminder (31 bits).
  @visibleForTesting
  static int notificationId(IptvReminder r) {
    var hash = 0x811c9dc5;
    for (final unit in '${r.sourceId}\u0000${r.channelId}\u0000${r.start}'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'iptv_reminders',
      'Programme reminders',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );

  Future<bool> _ensurePermission() async {
    if (_permissionAsked) return _permitted;
    _permissionAsked = true;
    try {
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        _permitted = await android?.requestNotificationsPermission() ?? true;
      } else if (Platform.isIOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
        _permitted = await ios?.requestPermissions(alert: true, sound: true) ?? false;
      } else if (Platform.isMacOS) {
        final mac = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
        _permitted = await mac?.requestPermissions(alert: true, sound: true) ?? false;
      }
    } catch (e) {
      appLogger.w('[iptv] notification permission request failed (${e.runtimeType})');
      _permitted = false;
    }
    if (!_permitted) appLogger.i('[iptv] notifications not allowed; reminders stay in the app');
    return _permitted;
  }

  @override
  bool get schedulesAhead => !Platform.isLinux;

  String _body(IptvReminder r) => t.liveTv.reminderMessage(title: r.title, channel: r.channelName ?? '');

  @override
  Future<bool> schedule(IptvReminder reminder, DateTime at) async {
    if (!schedulesAhead || !await _ensurePermission()) return false;
    try {
      await _plugin.zonedSchedule(
        id: notificationId(reminder),
        scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
        notificationDetails: _details,
        // Inexact: needs no exact-alarm permission; Android may fire it a
        // little late, which the minute's lead absorbs.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: t.liveTv.reminderTitle,
        body: _body(reminder),
        payload: reminderPayload(reminder),
      );
      return true;
    } catch (e) {
      appLogger.w('[iptv] reminder not scheduled with the system (${e.runtimeType})');
      return false;
    }
  }

  @override
  Future<void> cancel(IptvReminder reminder) async {
    try {
      await _plugin.cancel(id: notificationId(reminder));
    } catch (_) {}
  }

  @override
  Future<bool> showNow(IptvReminder reminder) async {
    if (!await _ensurePermission()) return false;
    try {
      await _plugin.show(
        id: notificationId(reminder),
        title: t.liveTv.reminderTitle,
        body: _body(reminder),
        notificationDetails: _details,
        payload: reminderPayload(reminder),
      );
      return true;
    } catch (e) {
      appLogger.w('[iptv] reminder notification failed (${e.runtimeType})');
      return false;
    }
  }
}
