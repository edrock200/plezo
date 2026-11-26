/// Catch-up (archive) URL building for IPTV channels.
///
/// Playlists describe catch-up with `catchup` (the mode), `catchup-source`
/// (a template) and `catchup-days`; Xtream servers with `tv_archive` and
/// `tv_archive_duration`. The modes follow what IPTV players commonly accept:
///
/// - `default`: [source] is a whole URL template.
/// - `append`: [source] is appended to the channel URL.
/// - `shift` / `timeshift`: `utc={utc}&lutc={lutc}` is appended.
/// - `flussonic` (`flussonic-hls`, `flussonic-ts`, `fs`): the channel URL's
///   last path element becomes `timeshift_abs-{utc}.ts`, `index-{utc}-{duration}.m3u8`
///   or `video-{utc}-{duration}.m3u8`.
/// - `xc`: an Xtream-style URL (`…/{user}/{pass}/{id}`) becomes
///   `…/timeshift/{user}/{pass}/{minutes}/{Y-m-d:H-M}/{id}.ts`.
///
/// Template placeholders (all times UTC unless noted): `{utc}` / `${start}` /
/// `{start}` start epoch seconds, `{utcend}` / `${end}` / `{end}` end, `{lutc}` /
/// `{now}` / `{timestamp}` now, `{duration}` seconds, `{duration:60}` (divided),
/// `{offset}` / `{offset:60}` seconds from start to now, `{Y}{m}{d}{H}{M}{S}`
/// start parts, `{utc:YmdHMS}` / `${start:YmdHMS}` / `{(b)YmdHMS}` formatted start
/// (letters Y m d H M S), `{(e)YmdHMS}` formatted end, `{catchup-id}`.
enum IptvCatchupMode {
  none,
  defaultMode,
  append,
  shift,
  flussonic,
  xtream;

  static IptvCatchupMode parse(String? raw) => switch ((raw ?? '').trim().toLowerCase()) {
    '' => none,
    'default' => defaultMode,
    'append' => append,
    'shift' || 'timeshift' => shift,
    'flussonic' || 'flussonic-hls' || 'flussonic-ts' || 'fs' => flussonic,
    'xc' => xtream,
    _ => none,
  };

  String get id => switch (this) {
    none => '',
    defaultMode => 'default',
    append => 'append',
    shift => 'shift',
    flussonic => 'flussonic',
    xtream => 'xc',
  };
}

class IptvCatchup {
  const IptvCatchup._();

  /// The archive URL for [channelUrl] from [start] for [duration], or null
  /// when [mode] cannot build one from what was given.
  static String? build({
    required IptvCatchupMode mode,
    required String channelUrl,
    String? source,
    required DateTime start,
    required Duration duration,
    DateTime? now,
    String? catchupId,
  }) {
    final at = start.toUtc();
    final current = (now ?? DateTime.now()).toUtc();
    switch (mode) {
      case IptvCatchupMode.none:
        return null;
      case IptvCatchupMode.defaultMode:
        if (source == null || source.trim().isEmpty) return null;
        // A relative source rides on the channel URL.
        final template = source.contains('://') ? source : _appendQuery(channelUrl, source);
        return fill(template, start: at, duration: duration, now: current, catchupId: catchupId);
      case IptvCatchupMode.append:
        if (source == null || source.trim().isEmpty) {
          return fill(_appendQuery(channelUrl, 'utc={utc}&lutc={lutc}'), start: at, duration: duration, now: current);
        }
        return fill('$channelUrl$source', start: at, duration: duration, now: current, catchupId: catchupId);
      case IptvCatchupMode.shift:
        return fill(_appendQuery(channelUrl, 'utc={utc}&lutc={lutc}'), start: at, duration: duration, now: current);
      case IptvCatchupMode.flussonic:
        return _flussonic(channelUrl, at, duration);
      case IptvCatchupMode.xtream:
        return xtreamFromChannelUrl(channelUrl, at, duration);
    }
  }

  static String _appendQuery(String url, String query) {
    final q = query.startsWith('?') || query.startsWith('&') ? query.substring(1) : query;
    return url.contains('?') ? '$url&$q' : '$url?$q';
  }

  static String _flussonic(String channelUrl, DateTime start, Duration duration) {
    final uri = Uri.parse(channelUrl);
    final segments = [...uri.pathSegments];
    if (segments.isEmpty) return channelUrl;
    final utc = start.millisecondsSinceEpoch ~/ 1000;
    final seconds = duration.inSeconds;
    final last = segments.removeLast();
    final String replacement;
    if (last.endsWith('.m3u8')) {
      final base = last.substring(0, last.length - 5);
      // `index.m3u8` / `video.m3u8` / `mono.m3u8` keep their stem.
      replacement = '$base-$utc-$seconds.m3u8';
    } else if (last == 'mpegts' || last.endsWith('.ts')) {
      replacement = 'timeshift_abs-$utc.ts';
    } else {
      // `http://host/channel?token=` without a file: Flussonic's TS archive.
      segments.add(last);
      replacement = 'timeshift_abs-$utc.ts';
    }
    segments.add(replacement);
    return uri.replace(pathSegments: segments).toString();
  }

  /// `http://host[:port]/[live/]{user}/{pass}/{id}[.ext]` →
  /// `http://host[:port]/timeshift/{user}/{pass}/{minutes}/{Y-m-d:H-M}/{id}.ts`.
  static String? xtreamFromChannelUrl(String channelUrl, DateTime start, Duration duration) {
    final uri = Uri.tryParse(channelUrl);
    if (uri == null) return null;
    final segments = [...uri.pathSegments.where((s) => s.isNotEmpty)];
    if (segments.isNotEmpty && segments.first == 'live') segments.removeAt(0);
    if (segments.length < 3) return null;
    final idPart = segments[segments.length - 1];
    final pass = segments[segments.length - 2];
    final user = segments[segments.length - 3];
    final dot = idPart.indexOf('.');
    final id = dot < 0 ? idPart : idPart.substring(0, dot);
    final prefix = segments.sublist(0, segments.length - 3);
    final base = uri.replace(pathSegments: const [], query: null).toString().replaceAll(RegExp(r'/+$'), '');
    final head = prefix.isEmpty ? base : '$base/${prefix.join('/')}';
    return xtreamTimeshiftUrl(
      base: head,
      username: user,
      password: pass,
      streamId: id,
      start: start,
      duration: duration,
    );
  }

  /// Xtream's archive route. The start is written in the server's own clock
  /// ([serverOffset] from UTC; Xtream's `server_info.timezone`).
  static String xtreamTimeshiftUrl({
    required String base,
    required String username,
    required String password,
    required String streamId,
    required DateTime start,
    required Duration duration,
    Duration serverOffset = Duration.zero,
    bool phpRoute = false,
  }) {
    final minutes = (duration.inSeconds / 60).ceil().clamp(1, 24 * 60);
    final local = start.toUtc().add(serverOffset);
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${local.year}-${two(local.month)}-${two(local.day)}:${two(local.hour)}-${two(local.minute)}';
    final u = Uri.encodeComponent(username);
    final p = Uri.encodeComponent(password);
    if (phpRoute) {
      return '$base/streaming/timeshift.php?username=$u&password=$p&stream=$streamId&start=$stamp&duration=$minutes';
    }
    return '$base/timeshift/$u/$p/$minutes/$stamp/$streamId.ts';
  }

  static final RegExp _placeholder = RegExp(r'\$?\{([^}]*)\}');

  /// Replace every placeholder of [template].
  static String fill(
    String template, {
    required DateTime start,
    required Duration duration,
    required DateTime now,
    String? catchupId,
  }) {
    final startUtc = start.toUtc();
    final endUtc = startUtc.add(duration);
    final nowUtc = now.toUtc();
    int epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    final offset = epoch(nowUtc) - epoch(startUtc);
    return template.replaceAllMapped(_placeholder, (m) {
      final raw = m.group(1)!;
      final colon = raw.indexOf(':');
      final name = (colon < 0 ? raw : raw.substring(0, colon)).trim();
      final arg = colon < 0 ? null : raw.substring(colon + 1);
      int divided(int value) {
        final d = int.tryParse(arg ?? '');
        return d == null || d <= 0 ? value : value ~/ d;
      }

      switch (name) {
        case 'utc' || 'start' || 'timestamp_start':
          return arg != null && int.tryParse(arg) == null ? format(startUtc, arg) : '${epoch(startUtc)}';
        case 'utcend' || 'end':
          return arg != null && int.tryParse(arg) == null ? format(endUtc, arg) : '${epoch(endUtc)}';
        case 'lutc' || 'now' || 'timestamp':
          return arg != null && int.tryParse(arg) == null ? format(nowUtc, arg) : '${epoch(nowUtc)}';
        case 'duration':
          return '${divided(duration.inSeconds)}';
        case 'offset':
          return '${divided(offset)}';
        case 'catchup-id':
          return catchupId ?? '';
        case 'Y':
          return '${startUtc.year}';
        case 'm':
          return _two(startUtc.month);
        case 'd':
          return _two(startUtc.day);
        case 'H':
          return _two(startUtc.hour);
        case 'M':
          return _two(startUtc.minute);
        case 'S':
          return _two(startUtc.second);
        case '(b)YmdHMS' || '(b)':
          return format(startUtc, arg ?? 'YmdHMS');
        case '(e)YmdHMS' || '(e)':
          return format(endUtc, arg ?? 'YmdHMS');
      }
      if (name.startsWith('(b)')) return format(startUtc, name.substring(3));
      if (name.startsWith('(e)')) return format(endUtc, name.substring(3));
      return m.group(0)!;
    });
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Format with the letters Y m d H M S (anything else is copied).
  static String format(DateTime t, String pattern) {
    final out = StringBuffer();
    for (final ch in pattern.split('')) {
      out.write(switch (ch) {
        'Y' => '${t.year}',
        'm' => _two(t.month),
        'd' => _two(t.day),
        'H' => _two(t.hour),
        'M' => _two(t.minute),
        'S' => _two(t.second),
        _ => ch,
      });
    }
    return out.toString();
  }
}
