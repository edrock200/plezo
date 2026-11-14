import '../../media/media_version.dart';
import '../../models/transcode_quality_preset.dart';
import 'silo_mappers.dart';

/// One edition (cut) of a Silo item, with every presentation of it merged: a
/// single file and a multi-part set of the same cut are one edition.
class SiloEdition {
  /// The trimmed `edition_key`; '' is the unnamed edition.
  final String id;

  /// The edition's name as the server sent it (`edition_raw`), if any.
  final String? raw;

  /// Indexes into the watch `versions` the Version menu offers, in server
  /// order: each presentation's first part with variants, else every file.
  final List<int> versionIndexes;

  /// Every file of the edition, all parts.
  final Set<String> fileIds;

  const SiloEdition({required this.id, required this.raw, required this.versionIndexes, required this.fileIds});

  /// The edition's display name, or null for the unnamed edition (the UI
  /// says "Standard"), as Silo's `editionLabel`.
  String? get label => siloEditionLabel(raw, id);
}

/// An edition's name as Silo's apps show it: the raw name, else the key with
/// `_`/`-` as spaces and each word capitalised (IMAX kept upper case).
String? siloEditionLabel(String? raw, String? key) {
  final name = raw?.trim();
  if (name != null && name.isNotEmpty) return name;
  final words = (key ?? '').trim().split(RegExp('[_-]+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return null;
  return words.map((w) => w.toLowerCase() == 'imax' ? 'IMAX' : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}

/// The file a Silo item page shows and Play starts, ported from Silo's
/// `DetailVersionSelector` (Silo Android #899, the rule web, Apple and Roku
/// share). Edition picks the cut; Version Auto picks the best first-part file
/// within it for the quality preference and never changes the cut.
///
/// Works on the raw watch-detail maps (`versions`, `playback_variants`).
abstract final class SiloVersionSelector {
  static const _sequentialPartKinds = {'multipart_movie', 'split_episode'};

  /// The server's resolution rank (its quality order, with the 4K/8K
  /// aliases); 0 is unknown, including resolutions outside that list.
  static int resolutionRank(Object? resolution) => switch (resolution?.toString().trim().toLowerCase()) {
    '480p' => 1,
    '720p' => 2,
    '1080p' => 3,
    '2160p' || '4k' => 4,
    '4320p' || '8k' => 5,
    _ => 0,
  };

  /// The rank [preset] caps Auto at; null (no cap) for Original.
  static int? capRank(TranscodeQualityPreset? preset) {
    final height = preset?.resolutionHeight;
    if (height == null) return null;
    if (height >= 4320) return 5;
    if (height >= 2160) return 4;
    if (height >= 1080) return 3;
    if (height >= 720) return 2;
    return 1;
  }

  static String normalizedEditionKey(Object? key) => key?.toString().trim() ?? '';

  static Iterable<Map<String, dynamic>> _files(Map<String, dynamic>? part) {
    final list = part?['versions'];
    return list is List ? list.whereType<Map<String, dynamic>>() : const [];
  }

  static String? _id(Map<String, dynamic> version) => version['file_id']?.toString();

  static int? _partIndex(Map<String, dynamic> version) {
    final value = version['presentation_part_index'];
    return value is num && value > 0 ? value.toInt() : null;
  }

  static bool _isSequentialPart(Map<String, dynamic> v) =>
      _sequentialPartKinds.contains(v['presentation_kind']) && _partIndex(v) != null;

  static bool _samePresentation(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['presentation_kind'] == b['presentation_kind'] &&
      a['presentation_group_key'] == b['presentation_group_key'] &&
      a['edition_key'] == b['edition_key'];

  /// The first part of [selected]'s presentation (preferring its
  /// resolution), or [selected] itself when it is not a later part.
  static Map<String, dynamic> firstPlaybackPart(List<Map<String, dynamic>> versions, Map<String, dynamic> selected) {
    if (!_isSequentialPart(selected)) return selected;
    final parts = versions.where((v) => _isSequentialPart(v) && _samePresentation(v, selected)).toList();
    if (parts.isEmpty) return selected;
    final firstIndex = parts.map((v) => _partIndex(v)!).reduce((a, b) => a < b ? a : b);
    if (_partIndex(selected) == firstIndex) return selected;
    final candidates = parts.where((v) => _partIndex(v) == firstIndex).toList();
    return candidates.firstWhere((v) => v['resolution'] == selected['resolution'], orElse: () => candidates.first);
  }

  /// The editions of an item, one per edition key, in server order (of
  /// [variants], else of first appearance in [versions]).
  static List<SiloEdition> editions(List<Map<String, dynamic>> versions, [List<Map<String, dynamic>>? variants]) {
    final indexById = <String, int>{};
    for (var i = 0; i < versions.length; i++) {
      final id = _id(versions[i]);
      if (id != null) indexById.putIfAbsent(id, () => i);
    }
    String? firstRaw(Iterable<Object?> raws) {
      for (final raw in raws) {
        final text = raw?.toString().trim();
        if (text != null && text.isNotEmpty) return text;
      }
      return null;
    }

    if (variants != null && variants.isNotEmpty) {
      final byKey = <String, List<Map<String, dynamic>>>{};
      for (final variant in variants) {
        byKey.putIfAbsent(normalizedEditionKey(variant['edition_key']), () => []).add(variant);
      }
      final out = <SiloEdition>[];
      for (final MapEntry(:key, value: cut) in byKey.entries) {
        final offered = <int>{};
        final fileIds = <String>{};
        for (final variant in cut) {
          final parts = (variant['parts'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
          Map<String, dynamic>? first;
          for (final part in parts) {
            final index = part['part_index'];
            final firstIndex = first?['part_index'];
            if (first == null || (index is num && (firstIndex is! num || index < firstIndex))) first = part;
            for (final file in _files(part)) {
              final id = _id(file);
              if (id != null) fileIds.add(id);
            }
          }
          for (final file in _files(first)) {
            final index = indexById[_id(file)];
            if (index != null) offered.add(index);
          }
        }
        if (offered.isEmpty) continue;
        out.add(
          SiloEdition(
            id: key,
            raw: firstRaw(cut.map((v) => v['edition_raw'])),
            versionIndexes: offered.toList()..sort(),
            fileIds: fileIds,
          ),
        );
      }
      if (out.isNotEmpty) return out;
    }
    final byKey = <String, List<int>>{};
    for (var i = 0; i < versions.length; i++) {
      byKey.putIfAbsent(normalizedEditionKey(versions[i]['edition_key']), () => []).add(i);
    }
    return [
      for (final MapEntry(:key, value: indexes) in byKey.entries)
        SiloEdition(
          id: key,
          raw: firstRaw(indexes.map((i) => versions[i]['edition_raw'])),
          versionIndexes: indexes,
          fileIds: indexes.map((i) => _id(versions[i])).nonNulls.toSet(),
        ),
    ];
  }

  /// The index of the file Version Auto picks in [edition] for [capRank].
  static int autoIndex(List<Map<String, dynamic>> versions, SiloEdition edition, int? capRank) {
    final offered = [for (final i in edition.versionIndexes) versions[i]];
    final firstParts = [
      for (final i in edition.versionIndexes)
        if (identical(firstPlaybackPart(offered, versions[i]), versions[i])) i,
    ];
    return _autoFile(versions, firstParts.isEmpty ? edition.versionIndexes : firstParts, capRank);
  }

  /// Version Auto among [candidates]: the best file at or below [capRank]
  /// (null is no cap), else the closest above it. A file of unknown
  /// resolution is picked only when no file's resolution is known.
  static int _autoFile(List<Map<String, dynamic>> versions, List<int> candidates, int? capRank) {
    final ordered = _serverOrder(versions, candidates);
    int rank(int i) => resolutionRank(versions[i]['resolution']);
    final known = ordered.where((i) => rank(i) > 0).toList();
    if (known.isEmpty) return ordered.first;
    if (capRank == null) return known.first;
    for (final i in known) {
      if (rank(i) <= capRank) return i;
    }
    final closest = known.map(rank).reduce((a, b) => a < b ? a : b);
    return known.firstWhere((i) => rank(i) == closest);
  }

  /// The server's version order: resolution, then HDR before SDR, then the
  /// larger file; list order otherwise (stable).
  static List<int> _serverOrder(List<Map<String, dynamic>> versions, List<int> candidates) {
    int size(int i) => (versions[i]['file_size'] as num?)?.toInt() ?? 0;
    final list = [...candidates];
    final position = {for (var p = 0; p < list.length; p++) list[p]: p};
    list.sort((a, b) {
      final byRank = resolutionRank(versions[b]['resolution']).compareTo(resolutionRank(versions[a]['resolution']));
      if (byRank != 0) return byRank;
      final byHdr = (versions[b]['hdr'] == true ? 1 : 0).compareTo(versions[a]['hdr'] == true ? 1 : 0);
      if (byHdr != 0) return byHdr;
      final bySize = size(b).compareTo(size(a));
      if (bySize != 0) return bySize;
      return position[a]!.compareTo(position[b]!);
    });
    return list;
  }

  /// 0 for the unnamed or standard edition, 1 for a theatrical one, 2 for any other cut.
  static int _preference(SiloEdition edition) {
    final names = [edition.id, ?edition.raw].map((n) => n.trim().toLowerCase()).where((n) => n.isNotEmpty);
    if (names.isEmpty) return 0;
    if (names.any((n) => n == 'standard' || n == 'default' || n.startsWith('standard ') || n.endsWith(' standard'))) {
      return 0;
    }
    if (names.any((n) => n.contains('theatrical'))) return 1;
    return 2;
  }

  /// The edition a page opens on with no history: each edition's Auto file
  /// compared across cuts by fit (within the cap, above it, unknown), then
  /// resolution (higher within the cap, lower above it), then HDR, then
  /// edition preference, then server order. File size is not compared.
  static SiloEdition _openingEdition(List<Map<String, dynamic>> versions, List<SiloEdition> editions, int? capRank) {
    int fit(int rank) => rank == 0 ? 2 : (capRank == null || rank <= capRank ? 0 : 1);
    final candidates = [
      for (var i = 0; i < editions.length; i++)
        (index: i, edition: editions[i], auto: versions[autoIndex(versions, editions[i], capRank)]),
    ];
    candidates.sort((a, b) {
      final rankA = resolutionRank(a.auto['resolution']);
      final rankB = resolutionRank(b.auto['resolution']);
      final fitA = fit(rankA);
      final fitB = fit(rankB);
      if (fitA != fitB) return fitA.compareTo(fitB);
      final byRank = fitA == 1 ? rankA.compareTo(rankB) : rankB.compareTo(rankA);
      if (byRank != 0) return byRank;
      final byHdr = (b.auto['hdr'] == true ? 1 : 0).compareTo(a.auto['hdr'] == true ? 1 : 0);
      if (byHdr != 0) return byHdr;
      final byPreference = _preference(a.edition).compareTo(_preference(b.edition));
      if (byPreference != 0) return byPreference;
      return a.index.compareTo(b.index);
    });
    return candidates.first.edition;
  }

  /// The last-played edition: [lastEditionKey] when it names one (a present
  /// '' names the unnamed edition), else the edition of [lastFileId].
  static SiloEdition? _lastPlayedEdition(List<SiloEdition> editions, String? lastFileId, String? lastEditionKey) {
    if (lastEditionKey != null) {
      final key = lastEditionKey.trim();
      for (final edition in editions) {
        if (edition.id == key) return edition;
      }
    }
    if (lastFileId == null) return null;
    for (final edition in editions) {
      if (edition.fileIds.contains(lastFileId)) return edition;
    }
    return null;
  }

  /// The edition the page shows: [editionId] (the viewer's pick), else the
  /// last-played one, else the opening edition. Null without versions.
  static SiloEdition? currentEdition({
    required List<Map<String, dynamic>> versions,
    List<Map<String, dynamic>>? variants,
    String? editionId,
    String? lastFileId,
    String? lastEditionKey,
    int? capRank,
  }) {
    final all = editions(versions, variants);
    if (all.isEmpty) return null;
    if (editionId != null) {
      for (final edition in all) {
        if (edition.id == editionId) return edition;
      }
    }
    return _lastPlayedEdition(all, lastFileId, lastEditionKey) ?? _openingEdition(versions, all, capRank);
  }

  /// The index of the file the page shows and Play starts.
  ///
  /// [pinnedFileId] (an explicit Version pick) wins. Otherwise the edition is
  /// [currentEdition]'s, and Auto is its best first-part file for [capRank],
  /// except that while the item has a resume point ([inProgress]) a later
  /// part of a multi-part item the viewer stopped in is kept, so Resume
  /// continues that part. -1 when there are no versions.
  static int select({
    required List<Map<String, dynamic>> versions,
    List<Map<String, dynamic>>? variants,
    String? pinnedFileId,
    String? editionId,
    String? lastFileId,
    String? lastEditionKey,
    bool inProgress = false,
    int? capRank,
  }) {
    if (versions.isEmpty) return -1;
    if (pinnedFileId != null) {
      final pinned = versions.indexWhere((v) => _id(v) == pinnedFileId);
      if (pinned >= 0) return pinned;
    }
    final edition = currentEdition(
      versions: versions,
      variants: variants,
      editionId: editionId,
      lastFileId: lastFileId,
      lastEditionKey: lastEditionKey,
      capRank: capRank,
    );
    if (edition == null) return 0;
    final lastIndex = lastFileId == null ? -1 : versions.indexWhere((v) => _id(v) == lastFileId);
    if (inProgress &&
        lastIndex >= 0 &&
        edition.fileIds.contains(lastFileId) &&
        !identical(firstPlaybackPart(versions, versions[lastIndex]), versions[lastIndex])) {
      return lastIndex;
    }
    return autoIndex(versions, edition, capRank);
  }

  /// The history fields of a watch-detail payload [select] reads.
  static ({String? lastFileId, String? lastEditionKey, bool inProgress}) history(Map<String, dynamic>? watch) {
    final userData = watch?['user_data'];
    if (userData is! Map) return (lastFileId: null, lastEditionKey: null, inProgress: false);
    final position = userData['position_seconds'];
    final key = userData['last_edition_key'];
    return (
      lastFileId: userData['last_file_id']?.toString(),
      lastEditionKey: key is String ? key : null,
      // A saved position above 0 is a resume point; `played` is ignored
      // (the server resets the position when a title finishes).
      inProgress: position is num && position > 0,
    );
  }

  static List<Map<String, dynamic>> variantsOf(Map<String, dynamic>? watch) {
    final list = watch?['playback_variants'];
    return list is List ? list.whereType<Map<String, dynamic>>().toList() : const [];
  }

  /// [select] for a watch-detail payload with no pin or edition pick: the
  /// file plain Play starts.
  static int selectForWatch(Map<String, dynamic>? watch, List<Map<String, dynamic>> versions, {int? capRank}) {
    final h = history(watch);
    return select(
      versions: versions,
      variants: variantsOf(watch),
      lastFileId: h.lastFileId,
      lastEditionKey: h.lastEditionKey,
      inProgress: h.inProgress,
      capRank: capRank,
    );
  }
}

/// What the Play Version menu offers for a Silo item: its editions, each
/// edition's files and Auto file, and the edition the page shows.
class SiloVersionMenu {
  /// Every playable file, in watch-detail order.
  final List<MediaVersion> versions;
  final List<SiloEdition> editions;

  /// The edition the page shows (last played, else the opening one).
  final SiloEdition current;

  /// The file plain Play starts.
  final int shownIndex;

  final List<Map<String, dynamic>> _raw;
  final int? _capRank;

  SiloVersionMenu._(this.versions, this.editions, this.current, this.shownIndex, this._raw, this._capRank);

  /// Null when no file has an id.
  static SiloVersionMenu? fromWatch(
    Map<String, dynamic>? watch,
    List<Map<String, dynamic>> rawVersions, {
    int? capRank,
  }) {
    final raw = rawVersions.where((v) => v['file_id'] != null).toList();
    if (raw.isEmpty) return null;
    final versions = raw.map(SiloMappers.version).nonNulls.toList();
    if (versions.length != raw.length) return null;
    final variants = SiloVersionSelector.variantsOf(watch);
    final h = SiloVersionSelector.history(watch);
    final editions = SiloVersionSelector.editions(raw, variants);
    final current = SiloVersionSelector.currentEdition(
      versions: raw,
      variants: variants,
      lastFileId: h.lastFileId,
      lastEditionKey: h.lastEditionKey,
      capRank: capRank,
    );
    if (current == null) return null;
    final shown = SiloVersionSelector.select(
      versions: raw,
      variants: variants,
      editionId: current.id,
      lastFileId: h.lastFileId,
      lastEditionKey: h.lastEditionKey,
      inProgress: h.inProgress,
      capRank: capRank,
    );
    return SiloVersionMenu._(versions, editions, current, shown, raw, capRank);
  }

  /// Whether the item has two or more editions (the Edition menu shows).
  bool get hasEditionChoices => editions.length > 1;

  /// The file Version Auto picks in [edition]; picking the edition keeps it.
  int autoIndex(SiloEdition edition) => SiloVersionSelector.autoIndex(_raw, edition, _capRank);
}
