import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:xml/xml_events.dart';

/// A `<channel>` of an XMLTV guide.
class XmltvChannel {
  final String id;
  final List<String> displayNames;
  final String? icon;

  const XmltvChannel({required this.id, this.displayNames = const [], this.icon});
}

/// A `<programme>` of an XMLTV guide. Times are epoch seconds (UTC).
class XmltvProgramme {
  final String channel;
  final int start;
  final int stop;
  final String title;
  final String? subTitle;
  final String? description;
  final String? category;
  final String? icon;

  /// `episode-num` in the `onscreen` system, or one built from `xmltv_ns`.
  final String? episode;
  final int? season;
  final int? episodeNumber;
  final String? rating;
  final int? year;

  const XmltvProgramme({
    required this.channel,
    required this.start,
    required this.stop,
    required this.title,
    this.subTitle,
    this.description,
    this.category,
    this.icon,
    this.episode,
    this.season,
    this.episodeNumber,
    this.rating,
    this.year,
  });
}

/// Streaming XMLTV reader.
///
/// Reads the guide as XML events (never a DOM), so a guide of hundreds of
/// megabytes passes through in the memory of one programme. Gzip input is
/// recognised by its magic bytes, whatever the URL says.
class XmltvStreamParser {
  XmltvStreamParser({required this.onChannel, required this.onProgramme, this.keepProgramme});

  final void Function(XmltvChannel channel) onChannel;
  final void Function(XmltvProgramme programme) onProgramme;

  /// Optional early filter on (channel, start, stop): a programme it refuses is
  /// skipped before its children are kept. Saves work on guide windows.
  final bool Function(String channel, int start, int stop)? keepProgramme;

  int channels = 0;
  int programmes = 0;
  int skipped = 0;

  /// Parse a byte stream, gzip or plain.
  Future<void> parseBytes(Stream<List<int>> bytes) => parseText(decodeBytes(bytes));

  /// UTF-8 text from a plain or gzip byte stream.
  static Stream<String> decodeBytes(Stream<List<int>> bytes) {
    return _maybeGunzip(bytes).transform(const Utf8Decoder(allowMalformed: true));
  }

  static Stream<List<int>> _maybeGunzip(Stream<List<int>> bytes) async* {
    final iterator = StreamIterator(bytes);
    try {
      List<int>? first;
      while (await iterator.moveNext()) {
        if (iterator.current.isNotEmpty) {
          first = iterator.current;
          break;
        }
      }
      if (first == null) return;
      final head = first;
      Stream<List<int>> all() async* {
        yield head;
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      }

      final isGzip = head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b;
      yield* isGzip ? all().transform(gzip.decoder) : all();
    } finally {
      await iterator.cancel();
    }
  }

  /// Parse XML text chunks.
  Future<void> parseText(Stream<String> text) async {
    await for (final events in text.transform(XmlEventDecoder())) {
      for (final event in events) {
        _event(event);
      }
    }
  }

  // State of the element being read.
  String? _section; // 'channel' | 'programme'
  String? _field; // child element whose text is collected
  final StringBuffer _text = StringBuffer();
  bool _skipCurrent = false;

  // channel
  String? _chId;
  final List<String> _chNames = [];
  String? _chIcon;

  // programme
  String? _pChannel;
  int? _pStart;
  int? _pStop;
  String? _pTitle;
  String? _pSub;
  String? _pDesc;
  String? _pCategory;
  String? _pIcon;
  String? _pEpisodeOnscreen;
  String? _pEpisodeNs;
  String? _pEpisodeSystem;
  String? _pRating;
  String? _pYear;
  bool _inRating = false;

  void _event(XmlEvent event) {
    switch (event) {
      case XmlStartElementEvent(:final name, :final attributes, :final isSelfClosing):
        _start(_local(name), attributes, isSelfClosing);
      case XmlEndElementEvent(:final name):
        _end(_local(name));
      case XmlTextEvent(:final value):
        if (_field != null && !_skipCurrent) _text.write(value);
      case XmlCDATAEvent(:final value):
        if (_field != null && !_skipCurrent) _text.write(value);
      default:
        break;
    }
  }

  static String _local(String name) {
    final colon = name.indexOf(':');
    return colon < 0 ? name : name.substring(colon + 1);
  }

  static String? _attr(List<XmlEventAttribute> attributes, String name) {
    for (final a in attributes) {
      if (a.name == name) return a.value;
    }
    return null;
  }

  void _start(String name, List<XmlEventAttribute> attributes, bool selfClosing) {
    if (_section == null) {
      if (name == 'channel') {
        _section = 'channel';
        _chId = _attr(attributes, 'id');
        _chNames.clear();
        _chIcon = null;
        if (selfClosing) _end('channel');
      } else if (name == 'programme') {
        _section = 'programme';
        _pChannel = _attr(attributes, 'channel');
        _pStart = parseXmltvTime(_attr(attributes, 'start'));
        _pStop = parseXmltvTime(_attr(attributes, 'stop'));
        _pTitle = _pSub = _pDesc = _pCategory = _pIcon = null;
        _pEpisodeOnscreen = _pEpisodeNs = _pEpisodeSystem = _pRating = _pYear = null;
        _inRating = false;
        final channel = _pChannel;
        final start = _pStart;
        _skipCurrent =
            channel == null ||
            start == null ||
            (keepProgramme != null && !keepProgramme!(channel, start, _pStop ?? start + 3600));
        if (selfClosing) _end('programme');
      }
      return;
    }
    if (_skipCurrent) return;
    if (_section == 'channel') {
      if (name == 'display-name') {
        _beginField(name);
      } else if (name == 'icon') {
        _chIcon ??= _attr(attributes, 'src');
      }
      return;
    }
    // programme children
    switch (name) {
      case 'title' || 'sub-title' || 'desc' || 'category' || 'date':
        _beginField(name);
      case 'episode-num':
        _pEpisodeSystem = _attr(attributes, 'system');
        _beginField(name);
      case 'icon':
        _pIcon ??= _attr(attributes, 'src');
      case 'rating':
        _inRating = true;
      case 'value':
        if (_inRating) _beginField('rating-value');
    }
    if (selfClosing && _field == name) _field = null;
  }

  void _beginField(String name) {
    _field = name;
    _text.clear();
  }

  void _end(String name) {
    if (_section == 'channel') {
      if (name == 'display-name' && _field == 'display-name') {
        final value = _text.toString().trim();
        if (value.isNotEmpty) _chNames.add(value);
        _field = null;
      } else if (name == 'channel') {
        final id = _chId?.trim();
        if (id != null && id.isNotEmpty) {
          channels++;
          onChannel(XmltvChannel(id: id, displayNames: List.of(_chNames), icon: _chIcon));
        }
        _section = null;
        _field = null;
      }
      return;
    }
    if (_section != 'programme') return;
    if (name == 'programme') {
      _finishProgramme();
      _section = null;
      _field = null;
      _skipCurrent = false;
      return;
    }
    if (_skipCurrent) return;
    if (name == 'rating') _inRating = false;
    final field = _field;
    if (field == null) return;
    final matches = field == name || (field == 'rating-value' && name == 'value');
    if (!matches) return;
    final value = _text.toString().trim();
    _field = null;
    if (value.isEmpty) return;
    switch (field) {
      case 'title':
        _pTitle ??= value;
      case 'sub-title':
        _pSub ??= value;
      case 'desc':
        _pDesc ??= value;
      case 'category':
        _pCategory ??= value;
      case 'date':
        _pYear ??= value;
      case 'episode-num':
        if (_pEpisodeSystem == 'xmltv_ns') {
          _pEpisodeNs ??= value;
        } else if (_pEpisodeSystem == 'onscreen' || _pEpisodeSystem == null) {
          _pEpisodeOnscreen ??= value;
        }
      case 'rating-value':
        _pRating ??= value;
    }
  }

  void _finishProgramme() {
    if (_skipCurrent) {
      skipped++;
      return;
    }
    final channel = _pChannel?.trim();
    final start = _pStart;
    if (channel == null || channel.isEmpty || start == null) {
      skipped++;
      return;
    }
    // A programme without a stop runs an hour (corrected later against the
    // next programme by the store).
    final stop = _pStop != null && _pStop! > start ? _pStop! : start + 3600;
    final ns = parseXmltvNs(_pEpisodeNs);
    final episode = _pEpisodeOnscreen ?? ns.label;
    programmes++;
    onProgramme(
      XmltvProgramme(
        channel: channel,
        start: start,
        stop: stop,
        title: _pTitle ?? '',
        subTitle: _pSub,
        description: _pDesc,
        category: _pCategory,
        icon: _pIcon,
        episode: episode,
        season: ns.season,
        episodeNumber: ns.episode,
        rating: _pRating,
        year: _pYear == null || _pYear!.length < 4 ? null : int.tryParse(_pYear!.substring(0, 4)),
      ),
    );
  }
}

/// XMLTV time: `YYYYMMDDhhmmss ±hhmm` (seconds, minutes and the zone are
/// optional; no zone means UTC). Returns epoch seconds, or null.
int? parseXmltvTime(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.length < 8) return null;
  var i = 0;
  while (i < text.length && _isDigit(text.codeUnitAt(i))) {
    i++;
  }
  final digits = text.substring(0, i);
  if (digits.length < 8) return null;
  int part(int from, int len) => digits.length >= from + len ? int.parse(digits.substring(from, from + len)) : 0;
  final year = part(0, 4);
  final month = part(4, 2);
  final day = part(6, 2);
  final hour = part(8, 2);
  final minute = part(10, 2);
  final second = part(12, 2);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  var offsetMinutes = 0;
  final rest = text.substring(i).trim();
  if (rest.isNotEmpty) {
    final sign = rest[0] == '-' ? -1 : (rest[0] == '+' ? 1 : 0);
    final body = sign == 0 ? '' : rest.substring(1).replaceAll(':', '');
    if (sign != 0 && body.length >= 2 && body.codeUnits.every(_isDigit)) {
      final hh = int.parse(body.substring(0, 2));
      final mm = body.length >= 4 ? int.parse(body.substring(2, 4)) : 0;
      offsetMinutes = sign * (hh * 60 + mm);
    }
  }
  final utc = DateTime.utc(year, month, day, hour, minute, second);
  return utc.millisecondsSinceEpoch ~/ 1000 - offsetMinutes * 60;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// `xmltv_ns` episode numbers are zero-based `season.episode.part`, each part
/// optionally `n/total`. Returns one-based numbers and an `S01E02` label.
({int? season, int? episode, String? label}) parseXmltvNs(String? raw) {
  if (raw == null) return (season: null, episode: null, label: null);
  final parts = raw.split('.');
  int? read(int index) {
    if (index >= parts.length) return null;
    final value = parts[index].split('/').first.trim();
    final n = int.tryParse(value);
    return n == null ? null : n + 1;
  }

  final season = read(0);
  final episode = read(1);
  if (season == null && episode == null) return (season: null, episode: null, label: null);
  final label = [
    if (season != null) 'S${season.toString().padLeft(2, '0')}',
    if (episode != null) 'E${episode.toString().padLeft(2, '0')}',
  ].join();
  return (season: season, episode: episode, label: label);
}
