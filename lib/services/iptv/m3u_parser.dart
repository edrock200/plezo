import 'dart:async';
import 'dart:convert';

/// The `#EXTM3U` header line of a playlist: guide addresses and the
/// playlist-wide catch-up defaults that each entry may override.
class M3uHeader {
  /// `url-tvg` / `x-tvg-url` / `tvg-url`, split on commas (several guides are
  /// common), in the order given.
  final List<String> epgUrls;
  final String? catchup;
  final String? catchupSource;
  final int? catchupDays;

  /// `tvg-shift` on the header: hours added to every channel's guide.
  final double? tvgShift;

  /// A playlist-wide `user-agent` / `http-user-agent` attribute (some
  /// players' extension).
  final String? userAgent;

  const M3uHeader({
    this.epgUrls = const [],
    this.catchup,
    this.catchupSource,
    this.catchupDays,
    this.tvgShift,
    this.userAgent,
  });

  static const empty = M3uHeader();

  factory M3uHeader.fromAttributes(Map<String, String> attrs) {
    final urls = <String>[];
    for (final key in const ['url-tvg', 'x-tvg-url', 'tvg-url']) {
      final value = attrs[key];
      if (value == null) continue;
      for (final part in value.split(',')) {
        final url = part.trim();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
    }
    return M3uHeader(
      epgUrls: urls,
      catchup: _nonEmpty(attrs['catchup'] ?? attrs['catchup-type']),
      catchupSource: _nonEmpty(attrs['catchup-source']),
      catchupDays: int.tryParse(attrs['catchup-days'] ?? ''),
      tvgShift: double.tryParse(attrs['tvg-shift'] ?? attrs['timeshift'] ?? ''),
      userAgent: _nonEmpty(attrs['user-agent'] ?? attrs['http-user-agent']),
    );
  }
}

/// One playlist entry: an `#EXTINF` line, the directives between it and its
/// URL, and the URL.
class M3uEntry {
  /// The stream URL without any `|Header=value` suffix.
  final String url;

  /// The title after the `#EXTINF` attributes' comma.
  final String title;

  /// `#EXTINF` attributes, keys lower-cased.
  final Map<String, String> attributes;

  /// `#EXTGRP` when the entry has no `group-title`.
  final String? extGroup;

  /// HTTP headers for the stream: `#EXTVLCOPT:http-user-agent` /
  /// `http-referrer` / `http-origin`, `#KODIPROP:inputstream.adaptive.*headers`
  /// and the URL's `|User-Agent=…&Referer=…` suffix (which wins).
  final Map<String, String> headers;

  /// `#EXTINF:<duration>`; -1 (or 0) for a live stream.
  final double? duration;

  /// Raw `#KODIPROP:` key/value pairs (licence and manifest hints are kept for
  /// diagnostics only).
  final Map<String, String> kodiProps;

  const M3uEntry({
    required this.url,
    required this.title,
    this.attributes = const {},
    this.extGroup,
    this.headers = const {},
    this.duration,
    this.kodiProps = const {},
  });

  String? attr(String key) => _nonEmpty(attributes[key]);

  String? get tvgId => attr('tvg-id');
  String? get tvgName => attr('tvg-name');
  String? get tvgLogo => attr('tvg-logo') ?? attr('logo');
  String? get tvgChno => attr('tvg-chno') ?? attr('channel-number') ?? attr('tvg-num') ?? attr('channel-id');
  String? get group => attr('group-title') ?? _nonEmpty(extGroup);
  double? get tvgShift => double.tryParse(attr('tvg-shift') ?? attr('timeshift') ?? '');
  String? get catchup => attr('catchup') ?? attr('catchup-type');
  int? get catchupDays => int.tryParse(attr('catchup-days') ?? attr('tvg-rec') ?? '');
  String? get catchupSource => attr('catchup-source');
  bool get isRadio => (attr('radio') ?? '').toLowerCase() == 'true';

  /// The best display name: the title, else `tvg-name`, else the URL's last
  /// path segment.
  String get displayName {
    final title = this.title.trim();
    if (title.isNotEmpty) return title;
    final name = tvgName;
    if (name != null) return name;
    final segments = Uri.tryParse(url)?.pathSegments ?? const [];
    return segments.isEmpty ? url : segments.last;
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A line-at-a-time M3U / M3U8 playlist parser.
///
/// It never holds more than the entry being assembled, so a playlist of tens
/// of thousands of entries streams through in constant memory. Feed it lines
/// with [addLine] (or a whole stream with [parse]); finished entries are
/// passed to the sink as their URL line arrives.
///
/// Tolerated variants: a UTF-8 byte-order mark, CRLF line ends, a missing
/// `#EXTM3U` header, unquoted or single-quoted attribute values, commas and
/// equals signs inside quoted values, attributes after the duration without a
/// space, `#EXTINF` lines without a title, and blank lines between an
/// `#EXTINF` and its URL.
class M3uStreamParser {
  M3uStreamParser(this._sink);

  final void Function(M3uEntry entry) _sink;

  M3uHeader _header = M3uHeader.empty;
  M3uHeader get header => _header;

  bool _first = true;
  int _entries = 0;
  int get entryCount => _entries;

  String? _title;
  Map<String, String> _attrs = const {};
  double? _duration;
  String? _extGroup;
  Map<String, String> _headers = {};
  Map<String, String> _kodi = {};

  /// Parse [lines] to the end, then return the header.
  static Future<M3uHeader> parse(Stream<String> lines, void Function(M3uEntry entry) sink) async {
    final parser = M3uStreamParser(sink);
    await for (final line in lines) {
      parser.addLine(line);
    }
    return parser.header;
  }

  /// Decode a byte stream (UTF-8, malformed bytes replaced) into lines.
  static Stream<String> linesOf(Stream<List<int>> bytes) =>
      bytes.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter());

  void addLine(String raw) {
    var line = raw;
    if (_first) {
      _first = false;
      if (line.isNotEmpty && line.codeUnitAt(0) == 0xFEFF) line = line.substring(1);
    }
    line = line.trim();
    if (line.isEmpty) return;
    if (line.startsWith('#')) {
      _directive(line);
      return;
    }
    _emit(line);
  }

  void _directive(String line) {
    final upper = line.length >= 16 ? line.substring(0, 16).toUpperCase() : line.toUpperCase();
    if (upper.startsWith('#EXTM3U')) {
      _header = M3uHeader.fromAttributes(parseAttributes(line.substring(7)).attributes);
      return;
    }
    if (upper.startsWith('#EXTINF')) {
      _reset();
      final body = line.length > 8 ? line.substring(8) : '';
      final parsed = parseExtInf(body);
      _duration = parsed.duration;
      _attrs = parsed.attributes;
      _title = parsed.title;
      return;
    }
    if (upper.startsWith('#EXTGRP:')) {
      _extGroup = line.substring(8).trim();
      return;
    }
    if (upper.startsWith('#EXTVLCOPT:')) {
      final option = line.substring(11).trim();
      final eq = option.indexOf('=');
      if (eq <= 0) return;
      final key = option.substring(0, eq).trim().toLowerCase();
      final value = option.substring(eq + 1).trim();
      if (value.isEmpty) return;
      switch (key) {
        case 'http-user-agent':
          _headers['User-Agent'] = value;
        case 'http-referrer' || 'http-referer':
          _headers['Referer'] = value;
        case 'http-origin':
          _headers['Origin'] = value;
      }
      return;
    }
    if (upper.startsWith('#KODIPROP:')) {
      final prop = line.substring(10).trim();
      final eq = prop.indexOf('=');
      if (eq <= 0) return;
      final key = prop.substring(0, eq).trim();
      final value = prop.substring(eq + 1).trim();
      _kodi[key] = value;
      final lower = key.toLowerCase();
      if (lower.endsWith('stream_headers') || lower.endsWith('manifest_headers')) {
        _headers.addAll(parseHeaderPairs(value));
      }
      return;
    }
    // Other directives (#EXTALB, #EXT-X-*, comments) are ignored.
  }

  void _emit(String line) {
    final split = splitUrlHeaders(line);
    final headers = {..._headers, ...split.headers};
    final attrs = _attrs;
    final entry = M3uEntry(
      url: split.url,
      title: _title ?? '',
      attributes: attrs,
      extGroup: _extGroup,
      headers: headers,
      duration: _duration,
      kodiProps: _kodi,
    );
    _entries++;
    _sink(entry);
    _reset();
  }

  void _reset() {
    _title = null;
    _attrs = const {};
    _duration = null;
    _extGroup = null;
    _headers = {};
    _kodi = {};
  }

  /// `#EXTINF:` body: `<duration> key="v" key2=v2,Title`.
  static ({double? duration, Map<String, String> attributes, String title}) parseExtInf(String body) {
    var i = 0;
    while (i < body.length && body.codeUnitAt(i) == 0x20) {
      i++;
    }
    final durStart = i;
    while (i < body.length) {
      final c = body.codeUnitAt(i);
      if (c == 0x20 || c == 0x2C || c == 0x09) break;
      // `-1tvg-id="x"`: attributes glued to the duration.
      if (!(c == 0x2D || c == 0x2E || (c >= 0x30 && c <= 0x39))) break;
      i++;
    }
    final duration = double.tryParse(body.substring(durStart, i));
    final parsed = parseAttributes(body.substring(i));
    return (duration: duration, attributes: parsed.attributes, title: parsed.rest.trim());
  }

  /// Reads `key=value` pairs until an unquoted comma; the text after it is
  /// [rest]. Keys are lower-cased. Values may be double-quoted, single-quoted
  /// or bare (ending at whitespace or the comma).
  static ({Map<String, String> attributes, String rest}) parseAttributes(String text) {
    final attrs = <String, String>{};
    var i = 0;
    final n = text.length;
    while (i < n) {
      // Skip separators.
      while (i < n && (text.codeUnitAt(i) == 0x20 || text.codeUnitAt(i) == 0x09)) {
        i++;
      }
      if (i >= n) break;
      if (text.codeUnitAt(i) == 0x2C) {
        return (attributes: attrs, rest: text.substring(i + 1));
      }
      final keyStart = i;
      while (i < n) {
        final c = text.codeUnitAt(i);
        if (c == 0x3D || c == 0x20 || c == 0x2C || c == 0x09) break;
        i++;
      }
      final key = text.substring(keyStart, i).toLowerCase();
      if (i >= n || text.codeUnitAt(i) != 0x3D) {
        // A bare word: not an attribute. Treat a following comma as the title
        // separator; otherwise keep scanning.
        if (i < n && text.codeUnitAt(i) == 0x2C) {
          return (attributes: attrs, rest: text.substring(i + 1));
        }
        continue;
      }
      i++; // '='
      String value;
      if (i < n && (text.codeUnitAt(i) == 0x22 || text.codeUnitAt(i) == 0x27)) {
        final quote = text.codeUnitAt(i);
        i++;
        final valueStart = i;
        while (i < n && text.codeUnitAt(i) != quote) {
          i++;
        }
        value = text.substring(valueStart, i);
        if (i < n) i++; // closing quote
      } else {
        final valueStart = i;
        while (i < n) {
          final c = text.codeUnitAt(i);
          if (c == 0x20 || c == 0x2C || c == 0x09) break;
          i++;
        }
        value = text.substring(valueStart, i);
      }
      if (key.isNotEmpty) attrs[key] = value.trim();
    }
    return (attributes: attrs, rest: '');
  }

  /// `http://x/y.ts|User-Agent=Foo&Referer=http://z` → the URL and headers.
  static ({String url, Map<String, String> headers}) splitUrlHeaders(String line) {
    final bar = line.indexOf('|');
    if (bar < 0) return (url: line, headers: const {});
    return (url: line.substring(0, bar).trim(), headers: parseHeaderPairs(line.substring(bar + 1)));
  }

  /// `User-Agent=Foo&Referer=http%3A%2F%2Fz` (values may be URL-encoded).
  static Map<String, String> parseHeaderPairs(String text) {
    final out = <String, String>{};
    for (final pair in text.split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final rawKey = pair.substring(0, eq).trim();
      var value = pair.substring(eq + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {
        // Keep the raw value.
      }
      if (value.isEmpty) continue;
      out[canonicalHeaderName(rawKey)] = value;
    }
    return out;
  }

  static String canonicalHeaderName(String raw) {
    final lower = raw.toLowerCase();
    return switch (lower) {
      'user-agent' || 'useragent' || 'http-user-agent' => 'User-Agent',
      'referer' || 'referrer' || 'http-referrer' || 'http-referer' => 'Referer',
      'origin' || 'http-origin' => 'Origin',
      'cookie' => 'Cookie',
      _ => raw,
    };
  }
}
