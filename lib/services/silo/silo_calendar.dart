import 'package:flutter/foundation.dart';

import 'silo_api.dart';

/// Silo's calendar (`GET /api/v2/calendar`): upcoming and recent episode
/// airings and movie releases, grouped by the viewer's local day.
///
/// Ports Silo's shared calendar model (`shared/.../model/calendar/CalendarModels.kt`,
/// `android-shared/.../common/calendar/CalendarTimeFormatter.kt`) and what
/// Silo's Android TV app shows (`TvCalendarScreen.kt`): the Following /
/// Trending / All views, a Monday-first week, badge pills and the air time.

/// The views Silo's apps offer (web, Apple and Android TV: Following,
/// Trending, All).
enum SiloCalendarFilter {
  following('following'),
  trending('trending'),
  all('all');

  const SiloCalendarFilter(this.wire);
  final String wire;
}

/// The poster pills Silo's apps draw (Silo Android #722 `calendarBadgeLabel`):
/// PREMIERE (series premiere), NEW SEASON, FINALE, and DIGITAL / PHYSICAL for
/// a movie listed on its home release.
enum SiloCalendarBadge { premiere, newSeason, finale, digital, physical }

/// The badges the card names, in the server's order, each once. Unknown
/// badges are skipped (Silo hides a badge it does not know).
List<SiloCalendarBadge> siloCalendarBadges(Iterable<Object?> raw) {
  final out = <SiloCalendarBadge>[];
  for (final value in raw) {
    final badge = switch (value is String ? value.toLowerCase() : null) {
      'series_premiere' => SiloCalendarBadge.premiere,
      'season_premiere' => SiloCalendarBadge.newSeason,
      'finale' || 'season_finale' || 'series_finale' => SiloCalendarBadge.finale,
      'digital' => SiloCalendarBadge.digital,
      'physical' => SiloCalendarBadge.physical,
      _ => null,
    };
    if (badge != null && !out.contains(badge)) out.add(badge);
  }
  return out;
}

/// A calendar day as a date-only value (local midnight).
DateTime siloCalendarDay(DateTime value) => DateTime(value.year, value.month, value.day);

/// Monday of the week holding [day].
DateTime siloCalendarWeekStart(DateTime day) {
  final d = siloCalendarDay(day);
  return DateTime(d.year, d.month, d.day - (d.weekday - DateTime.monday));
}

/// `YYYY-MM-DD`.
String siloCalendarYmd(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

DateTime? _parseYmd(Object? value) {
  if (value is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// The IANA zone the server reckons days in. Dart has no IANA name for the
/// device zone on every platform: a name that already reads as one
/// (`Europe/Paris`, as Linux and some Android builds report) is sent as it
/// is, UTC as `Etc/UTC`, and otherwise the whole-hour offset of [now] as
/// `Etc/GMT∓N` (Etc names count west as positive). A half-hour offset sends
/// none (the server then uses UTC). Days are regrouped on the device anyway
/// ([SiloCalendarWeek.from]), so the zone only decides the edges of the
/// window, which the fetch pads by a day.
String? siloCalendarTimeZone(DateTime now) {
  final name = now.timeZoneName.trim();
  if (_ianaLike(name)) return name;
  if (name == 'UTC' || name == 'GMT' || name == 'Etc/UTC') return 'Etc/UTC';
  final offset = now.timeZoneOffset;
  if (offset.inMinutes % 60 != 0) return null;
  final hours = offset.inHours;
  if (hours == 0) return 'Etc/UTC';
  return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
}

bool _ianaLike(String name) {
  final slash = name.indexOf('/');
  if (slash < 2 || slash == name.length - 1 || name.contains(' ')) return false;
  const areas = {
    'Africa',
    'America',
    'Antarctica',
    'Asia',
    'Atlantic',
    'Australia',
    'Europe',
    'Indian',
    'Pacific',
    'Etc',
  };
  return areas.contains(name.substring(0, slash));
}

/// One airing or release.
@immutable
class SiloCalendarItem {
  const SiloCalendarItem({
    required this.contentId,
    required this.type,
    required this.title,
    this.episodeTitle,
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
    this.airDate,
    this.airTime,
    this.airAt,
    this.localAirDate,
    this.posterUrl,
    this.watched = false,
    this.badges = const [],
  });

  /// Null for an event without identity (the contract forbids a blank one).
  static SiloCalendarItem? fromJson(Object? raw, {String Function(String url)? resolveUrl}) {
    if (raw is! Map) return null;
    final contentId = raw['content_id'];
    if (contentId is! String || contentId.trim().isEmpty) return null;
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    int? integer(Object? v) => v is num && v.isFinite ? v.toInt() : null;
    final poster = str(raw['poster_url']);
    final airAtText = str(raw['air_at']);
    return SiloCalendarItem(
      contentId: contentId,
      type: str(raw['type']) ?? '',
      title: str(raw['title']) ?? '',
      episodeTitle: str(raw['episode_title']),
      seriesId: str(raw['series_id']),
      seasonNumber: integer(raw['season_number']),
      episodeNumber: integer(raw['episode_number']),
      airDate: _parseYmd(raw['air_date']),
      airTime: str(raw['air_time']),
      airAt: airAtText == null ? null : DateTime.tryParse(airAtText),
      localAirDate: _parseYmd(raw['local_air_date']),
      posterUrl: poster == null ? null : (resolveUrl?.call(poster) ?? poster),
      watched: raw['watched'] == true,
      badges: siloCalendarBadges(raw['badges'] is List ? raw['badges'] as List : const []),
    );
  }

  final String contentId;
  final String type;
  final String title;
  final String? episodeTitle;
  final String? seriesId;
  final int? seasonNumber;
  final int? episodeNumber;
  final DateTime? airDate;

  /// The network's wall-clock time (`HH:MM`), a fallback for [airAt].
  final String? airTime;

  /// The airing as an instant (UTC), when the network's time and zone are known.
  final DateTime? airAt;

  /// The day the server lists the event under, in the zone it was sent.
  final DateTime? localAirDate;
  final String? posterUrl;
  final bool watched;
  final List<SiloCalendarBadge> badges;

  /// Episodes (and `season_premiere` events, which name a series).
  bool get isEpisode => type == 'episode' || (type != 'movie' && seriesId != null);

  bool get isMovie => type == 'movie';

  /// The device-local day the event falls on: the absolute [airAt] moved to
  /// local time when known, else the server's local day.
  DateTime? get localDay {
    final at = airAt;
    if (at != null) return siloCalendarDay(at.toLocal());
    return localAirDate ?? airDate;
  }

  /// When the event airs on the device's clock (`localDisplayAirTime`): the
  /// absolute [airAt] in local time when known (authoritative); else the
  /// network's wall clock [airTime] as it is (it cannot be converted safely),
  /// except `00:00` (date-only entries report midnight); else null. Only the
  /// hour and minute of the result mean anything.
  DateTime? get airClock {
    final at = airAt;
    if (at != null) return at.toLocal();
    final m = RegExp(r'^(\d{2}):(\d{2})').firstMatch(airTime ?? '');
    if (m == null) return null;
    final hour = int.parse(m.group(1)!);
    final minute = int.parse(m.group(2)!);
    if ((hour == 0 && minute == 0) || hour > 23 || minute > 59) return null;
    return DateTime(2000, 1, 1, hour, minute);
  }

  /// [airClock] as `21:05` or `9:05 PM` (locale-free; the page formats with
  /// the app's locale).
  String? airTimeLabel({required bool use24HourClock}) {
    final clock = airClock;
    if (clock == null) return null;
    final mm = clock.minute.toString().padLeft(2, '0');
    if (use24HourClock) return '${clock.hour.toString().padLeft(2, '0')}:$mm';
    final shown = clock.hour % 12 == 0 ? 12 : clock.hour % 12;
    return '$shown:$mm ${clock.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// Spoiler rule: an unwatched episode's own title is left out while
  /// Plezilo's "Hide spoilers" is on. Calendar artwork is always the series
  /// or movie poster (never an episode still), so nothing needs blurring.
  String? episodeTitleShown({required bool hideSpoilers}) =>
      hideSpoilers && isEpisode && !watched ? null : episodeTitle;
}

/// A week of events by local day, Monday first.
@immutable
class SiloCalendarWeek {
  const SiloCalendarWeek(this.start, this.days);

  final DateTime start;

  /// Seven entries, one per day (empty lists for quiet days).
  final List<List<SiloCalendarItem>> days;

  int get eventCount => days.fold(0, (sum, day) => sum + day.length);

  /// Groups [events] onto the week starting [start], by [SiloCalendarItem.localDay];
  /// events outside the week (the padded window's edges) are dropped. Within
  /// a day, events keep the server's airing order, timed ones by instant.
  factory SiloCalendarWeek.from(DateTime start, Iterable<SiloCalendarItem> events) {
    final weekStart = siloCalendarDay(start);
    final days = List.generate(7, (_) => <SiloCalendarItem>[]);
    final seen = <String>{};
    for (final event in events) {
      final day = event.localDay;
      if (day == null || !seen.add(event.contentId)) continue;
      final index = DateTime.utc(
        day.year,
        day.month,
        day.day,
      ).difference(DateTime.utc(weekStart.year, weekStart.month, weekStart.day)).inDays;
      if (index < 0 || index > 6) continue;
      days[index].add(event);
    }
    for (final day in days) {
      _stableSortByAirAt(day);
    }
    return SiloCalendarWeek(weekStart, [for (final day in days) List.unmodifiable(day)]);
  }

  static void _stableSortByAirAt(List<SiloCalendarItem> day) {
    final indexed = day.indexed.toList()
      ..sort((a, b) {
        final x = a.$2.airAt;
        final y = b.$2.airAt;
        if (x != null && y != null && x != y) return x.compareTo(y);
        return a.$1.compareTo(b.$1);
      });
    day
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }
}

/// The calendar call of one Silo client.
class SiloCalendarApi {
  SiloCalendarApi(this._api);

  final SiloApi _api;

  /// The week starting [weekStart] (a Monday). The window is padded by a day
  /// on each side (the server allows up to 31 days) so events the device
  /// moves across midnight are not lost.
  Future<SiloCalendarWeek> fetchWeek(
    DateTime weekStart, {
    SiloCalendarFilter filter = SiloCalendarFilter.following,
    DateTime? now,
  }) async {
    final start = siloCalendarDay(weekStart);
    final from = DateTime(start.year, start.month, start.day - 1);
    final to = DateTime(start.year, start.month, start.day + 7);
    final zone = siloCalendarTimeZone(now ?? DateTime.now());
    final data = await _api.getJson(
      '/api/v2/calendar',
      query: {'start': siloCalendarYmd(from), 'end': siloCalendarYmd(to), 'filter': filter.wire, 'timezone': ?zone},
    );
    final days = data['events'];
    if (days is! List) throw const FormatException('Calendar answer without events');
    final events = <SiloCalendarItem>[];
    for (final day in days) {
      final items = day is Map ? day['items'] : null;
      if (items is! List) throw const FormatException('Calendar day without items');
      for (final raw in items) {
        final item = SiloCalendarItem.fromJson(raw, resolveUrl: _api.resolveUrl);
        if (item != null) events.add(item);
      }
    }
    return SiloCalendarWeek.from(start, events);
  }
}
