import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// How a channel's guide was found.
enum IptvEpgMatch { manual, tvgId, name, none }

/// Matching playlist channels to XMLTV channels.
///
/// Order: the user's own choice, then `tvg-id` (exact, then case-insensitive),
/// then the normalised display name (`tvg-name`, then the title) against every
/// `<display-name>` of the guide.
class IptvEpgMatcher {
  IptvEpgMatcher({required Iterable<String> guideIds, required Map<String, String> guideNames}) {
    for (final id in guideIds) {
      _ids[id] = id;
      _lowerIds.putIfAbsent(id.toLowerCase(), () => id);
    }
    _names.addAll(guideNames);
  }

  final Map<String, String> _ids = {};
  final Map<String, String> _lowerIds = {};

  /// Normalised display name → guide channel id.
  final Map<String, String> _names = {};

  ({String? id, IptvEpgMatch how}) match({String? manual, String? tvgId, String? tvgName, String? title}) {
    if (manual != null && manual.isNotEmpty) return (id: manual, how: IptvEpgMatch.manual);
    if (tvgId != null && tvgId.isNotEmpty) {
      final exact = _ids[tvgId] ?? _lowerIds[tvgId.toLowerCase()];
      if (exact != null) return (id: exact, how: IptvEpgMatch.tvgId);
    }
    for (final name in [tvgName, title]) {
      if (name == null || name.isEmpty) continue;
      final key = normaliseChannelName(name);
      if (key.isEmpty) continue;
      final id = _names[key];
      if (id != null) return (id: id, how: IptvEpgMatch.name);
    }
    return (id: null, how: IptvEpgMatch.none);
  }
}

final RegExp _bracketed = RegExp(r'[\[(][^\])]*[\])]');
final RegExp _qualityTokens = RegExp(
  r'\b(uhd|fhd|hd|sd|hevc|h265|h264|4k|8k|1080p?|720p?|576p?|480p?|50fps|60fps|backup|raw|vip|multi)\b',
);
final RegExp _countryPrefix = RegExp(r'^([a-z]{2,3})\s*[:|]\s*');
final RegExp _nonAlnum = RegExp(r'[^a-z0-9]+');

/// A channel name reduced to what identifies it: accents folded, lower case,
/// bracketed notes, quality tags and a leading `UK:` / `US |` style country
/// prefix removed, and punctuation and spaces dropped. `"BBC One HD"`,
/// `"UK: BBC ONE (1080p)"` and `"bbc.one"` all become `bbcone`.
String normaliseChannelName(String name) {
  var s = unorm.nfkd(name).replaceAll(RegExp('[\\u0300-\\u036f]'), '').toLowerCase().trim();
  s = s.replaceAll(_bracketed, ' ');
  s = s.replaceFirst(_countryPrefix, '');
  s = s.replaceAll(_qualityTokens, ' ');
  s = s.replaceAll('&', 'and').replaceAll('+', 'plus');
  return s.replaceAll(_nonAlnum, '');
}
