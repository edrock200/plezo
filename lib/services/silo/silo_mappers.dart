import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_part.dart';
import '../../media/media_rating.dart';
import '../../media/media_role.dart';
import '../../media/media_source_info.dart';
import '../../media/media_stream.dart';
import '../../media/media_version.dart';
import '../../utils/json_utils.dart';

/// Everything a mapping needs from the client: who the items belong to and
/// how to make a server URL absolute.
class SiloMappingContext {
  final String serverId;
  final String? serverName;
  final String Function(String url) resolveUrl;

  const SiloMappingContext({required this.serverId, required this.serverName, required this.resolveUrl});
}

/// The coarse media family of a Silo library's free-text `type`, matched the
/// way Silo's own clients do (case-insensitively).
enum SiloLibraryFamily { video, audio, reading, unknown }

/// Pure JSON → neutral-model mapping for Silo `/api/v2` payloads.
abstract final class SiloMappers {
  /// Prefix of the synthetic season ids used where Silo names a season only
  /// by series and number (episode cards). The real season `content_id` is
  /// used wherever the server gives one.
  static const seasonIdPrefix = 'silo-season:';

  static String syntheticSeasonId(String seriesId, int seasonNumber) => '$seasonIdPrefix$seasonNumber:$seriesId';

  /// Parse a [syntheticSeasonId]; `null` for any other id.
  static ({String seriesId, int seasonNumber})? parseSyntheticSeasonId(String id) {
    if (!id.startsWith(seasonIdPrefix)) return null;
    final rest = id.substring(seasonIdPrefix.length);
    final colon = rest.indexOf(':');
    if (colon <= 0) return null;
    final number = int.tryParse(rest.substring(0, colon));
    final seriesId = rest.substring(colon + 1);
    if (number == null || seriesId.isEmpty) return null;
    return (seriesId: seriesId, seasonNumber: number);
  }

  static SiloLibraryFamily libraryFamily(String? type) {
    final value = (type ?? '').trim().toLowerCase();
    const video = {'movie', 'movies', 'series', 'show', 'shows', 'tv', 'tvshows', 'video', 'videos', 'mixed'};
    const audio = {
      'music',
      'album',
      'albums',
      'artist',
      'artists',
      'audio',
      'audiobook',
      'audiobooks',
      'podcast',
      'podcasts',
    };
    const reading = {'ebook', 'ebooks', 'book', 'books', 'comic', 'comics', 'manga', 'reading'};
    if (video.contains(value)) return SiloLibraryFamily.video;
    if (audio.contains(value)) return SiloLibraryFamily.audio;
    if (reading.contains(value)) return SiloLibraryFamily.reading;
    return SiloLibraryFamily.unknown;
  }

  static MediaKind libraryKind(String? type) {
    final value = (type ?? '').trim().toLowerCase();
    if (const {'movie', 'movies'}.contains(value)) return MediaKind.movie;
    if (const {'series', 'show', 'shows', 'tv', 'tvshows'}.contains(value)) return MediaKind.show;
    // `video` and `mixed` hold movies and shows side by side.
    return MediaKind.unknown;
  }

  static MediaLibrary? library(Map<String, dynamic> json, SiloMappingContext ctx) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final kind = libraryKind(json['type'] as String?);
    return MediaLibrary(
      id: id,
      backend: MediaBackend.silo,
      title: (json['name'] as String?) ?? id,
      kind: kind,
      defaultBrowseKinds: switch (kind) {
        MediaKind.movie => const [MediaKind.movie],
        MediaKind.show => const [MediaKind.show],
        _ => const [MediaKind.movie, MediaKind.show],
      },
      serverId: ctx.serverId,
      serverName: ctx.serverName,
    );
  }

  static MediaKind itemKind(String? type) => switch ((type ?? '').toLowerCase()) {
    'movie' || 'video' => MediaKind.movie,
    'series' || 'show' => MediaKind.show,
    'season' => MediaKind.season,
    'episode' => MediaKind.episode,
    'collection' => MediaKind.collection,
    _ => MediaKind.unknown,
  };

  /// Silo's catalog `type` filter value for a neutral kind.
  static String? catalogType(MediaKind? kind) => switch (kind) {
    MediaKind.movie => 'movie',
    MediaKind.show => 'series',
    MediaKind.episode => 'episode',
    _ => null,
  };

  static String? _string(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (value is num) return value.toString();
    return null;
  }

  static String? _url(Object? value, SiloMappingContext ctx) {
    final url = _string(value);
    return url == null ? null : ctx.resolveUrl(url);
  }

  static Map<String, dynamic>? _map(Object? value) => value is Map<String, dynamic> ? value : null;

  static List<String>? _strings(Object? value) {
    if (value is! List) return null;
    final out = value.map(_string).nonNulls.toList();
    return out.isEmpty ? null : out;
  }

  static double? _double(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static int? _epochSeconds(Object? iso) {
    final text = _string(iso);
    if (text == null) return null;
    final parsed = DateTime.tryParse(text);
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  static int? _secondsToMs(Object? seconds) {
    final value = _double(seconds);
    return value == null || value < 0 ? null : (value * 1000).round();
  }

  static List<MediaRatingSource>? _ratings(Map<String, dynamic> json) {
    final out = <MediaRatingSource>[];
    final imdb = _double(json['rating_imdb']);
    if (imdb != null && imdb > 0) out.add(MediaRatingSource(source: 'imdb', value: imdb));
    final tmdb = _double(json['rating_tmdb']);
    if (tmdb != null && tmdb > 0) out.add(MediaRatingSource(source: 'tmdb', value: tmdb));
    final critic = _double(json['rating_rt_critic']);
    if (critic != null && critic > 0) {
      out.add(MediaRatingSource(source: 'rottenTomatoesCritic', value: critic > 10 ? critic / 10 : critic));
    }
    final audience = _double(json['rating_rt_audience']);
    if (audience != null && audience > 0) {
      out.add(MediaRatingSource(source: 'rottenTomatoesAudience', value: audience > 10 ? audience / 10 : audience));
    }
    if (out.isEmpty) {
      // Detail responses carry `ratings: [{source, score}]` instead.
      final list = json['ratings'];
      if (list is List) {
        for (final entry in list.whereType<Map>()) {
          final source = (_string(entry['source']) ?? '').toLowerCase();
          final score = _double(entry['score']);
          if (score == null || score <= 0) continue;
          switch (source) {
            case 'imdb':
              out.add(MediaRatingSource(source: 'imdb', value: score));
            case 'tmdb':
              out.add(MediaRatingSource(source: 'tmdb', value: score > 10 ? score / 10 : score));
            case 'rt_critic' || 'rotten_tomatoes' || 'rottentomatoes':
              out.add(MediaRatingSource(source: 'rottenTomatoesCritic', value: score > 10 ? score / 10 : score));
            case 'rt_audience':
              out.add(MediaRatingSource(source: 'rottenTomatoesAudience', value: score > 10 ? score / 10 : score));
          }
        }
      }
    }
    return out.isEmpty ? null : out;
  }

  static List<MediaRole>? _cast(Object? list, SiloMappingContext ctx) {
    if (list is! List) return null;
    final out = <MediaRole>[];
    for (final entry in list.whereType<Map>()) {
      final name = _string(entry['name']);
      if (name == null) continue;
      out.add(
        MediaRole(
          id: _string(entry['person_id']),
          tag: name,
          role: _string(entry['character']),
          thumbPath: _url(entry['photo_url'], ctx),
        ),
      );
    }
    return out.isEmpty ? null : out;
  }

  static List<String>? _crew(Object? list, bool Function(String job) matches) {
    if (list is! List) return null;
    final out = <String>[
      for (final entry in list.whereType<Map>())
        if (matches((_string(entry['job']) ?? '').toLowerCase())) ?_string(entry['name']),
    ];
    return out.isEmpty ? null : out;
  }

  /// Video height of a Silo resolution label (`1080p`, `4K`, `2160p`, `SD`).
  static int? resolutionHeight(Object? resolution) {
    final text = (_string(resolution) ?? '').toLowerCase();
    if (text.isEmpty) return null;
    if (text == '4k' || text == 'uhd') return 2160;
    if (text == '8k') return 4320;
    if (text == 'sd') return 480;
    if (text == 'hd') return 720;
    return int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), ''));
  }

  static String? _resolutionLabel(Object? resolution) {
    final height = resolutionHeight(resolution);
    if (height == null) return null;
    if (height >= 2000) return '4k';
    if (height < 576) return 'sd';
    return '$height';
  }

  static List<MediaStream> _streams(Map<String, dynamic> version) {
    final out = <MediaStream>[];
    final fileId = _string(version['file_id']) ?? '';
    final audio = version['audio_tracks'];
    if (audio is List) {
      var position = 0;
      for (final track in audio.whereType<Map>()) {
        final index = flexibleInt(track['index']) ?? position;
        out.add(
          MediaStream(
            id: 'file:$fileId:audio:$index',
            kind: MediaStreamKind.audio,
            index: index,
            codec: _string(track['codec']),
            language: _string(track['language']),
            languageCode: _string(track['language']),
            title: _string(track['title']),
            channels: flexibleInt(track['channels']),
            isDefault: track['default'] == true,
          ),
        );
        position++;
      }
    }
    final subs = version['subtitle_tracks'];
    if (subs is List) {
      var position = 0;
      for (final track in subs.whereType<Map>()) {
        final index = flexibleInt(track['index']) ?? position;
        out.add(
          MediaStream(
            id: 'file:$fileId:subtitle:$index',
            kind: MediaStreamKind.subtitle,
            index: index,
            codec: _string(track['codec']),
            language: _string(track['language']),
            languageCode: _string(track['language']),
            title: _string(track['title']),
            isDefault: track['default'] == true,
            forced: track['forced'] == true,
          ),
        );
        position++;
      }
    }
    return out;
  }

  /// One playable file (`versions[]` on detail, `files[]` on episode rows).
  static MediaVersion? version(Map<String, dynamic> json) {
    final fileId = _string(json['file_id']);
    if (fileId == null) return null;
    final edition = _string(json['edition_raw']) ?? _string(json['edition_key']);
    return MediaVersion(
      id: fileId,
      height: resolutionHeight(json['resolution']),
      videoResolution: _resolutionLabel(json['resolution']),
      videoCodec: _string(json['codec_video']),
      bitrate: flexibleInt(json['bitrate']),
      container: _string(json['container']),
      name: edition,
      parts: [
        MediaPart(
          id: fileId,
          container: _string(json['container']),
          sizeBytes: flexibleInt(json['file_size']),
          durationMs: _secondsToMs(json['duration']),
          accessible: json['unreadable'] == true ? false : null,
          streams: _streams(json),
        ),
      ],
    );
  }

  static List<MediaVersion>? _versions(Map<String, dynamic> json) {
    final raw = json['versions'] ?? json['files'];
    if (raw is! List) return null;
    return raw.whereType<Map<String, dynamic>>().map(version).nonNulls.toList();
  }

  /// Map a Silo card or detail object. Returns `null` for rows without an
  /// id or of a type Plezy cannot show (audio and reading media).
  static MediaItem? item(Map<String, dynamic> json, SiloMappingContext ctx, {String? libraryId, String? libraryTitle}) {
    final id = _string(json['content_id']) ?? _string(json['id']);
    if (id == null) return null;
    final kind = itemKind(_string(json['type']) ?? (json.containsKey('episode_number') ? 'episode' : null));
    if (kind == MediaKind.unknown) return null;

    final userState = _map(json['user_state']);
    final userData = _map(json['user_data']);
    final played = userState?['played'] == true || userData?['played'] == true;
    final positionSeconds = _double(json['position_seconds']) ?? _double(userData?['position_seconds']);
    final durationMs =
        _secondsToMs(json['duration_seconds']) ??
        _secondsToMs(userData?['duration_seconds']) ??
        (flexibleInt(json['runtime']) == null ? null : flexibleInt(json['runtime'])! * 60000);

    final seasonNumber = flexibleInt(json['season_number']);
    final episodeNumber = flexibleInt(json['episode_number']);
    final seriesId = _string(json['series_id']);
    final seriesTitle = _string(json['series_title']);
    final poster = _url(json['poster_url'], ctx);
    final still = _url(json['still_url'], ctx);
    final backdrop = _url(json['backdrop_url'], ctx);
    final logo = _url(json['logo_url'], ctx);

    final episodeCount = flexibleInt(json['episode_count']);
    final unplayed = flexibleInt(userData?['unplayed_count']);
    final viewedLeaf = episodeCount != null && unplayed != null
        ? (episodeCount - unplayed).clamp(0, episodeCount)
        : (played && episodeCount != null ? episodeCount : null);

    String? title = _string(json['title']);
    String? parentId;
    String? parentTitle;
    int? parentIndex;
    int? index;
    String? grandparentId;
    String? grandparentTitle;
    String? thumbPath = poster;
    String? parentThumbPath;
    String? grandparentThumbPath;
    String? grandparentArtPath;

    switch (kind) {
      case MediaKind.episode:
        title = _string(json['episode_title']) ?? title;
        index = episodeNumber;
        parentIndex = seasonNumber;
        grandparentId = seriesId;
        grandparentTitle = seriesTitle;
        if (seriesId != null && seasonNumber != null) {
          parentId = _string(json['season_id']) ?? syntheticSeasonId(seriesId, seasonNumber);
        }
        parentTitle = seasonNumber == null ? null : (seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber');
        thumbPath = still ?? poster;
        grandparentThumbPath = poster;
        parentThumbPath = poster;
        grandparentArtPath = backdrop;
      case MediaKind.season:
        index = seasonNumber;
        parentId = seriesId;
        parentTitle = seriesTitle;
        parentThumbPath = poster;
        title ??= seasonNumber == null ? null : (seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber');
      default:
        break;
    }

    final genres = _strings(json['genres']);
    final studios = _strings(json['studios']) ?? _strings(json['networks']);
    final ratings = _ratings(json);

    return MediaItem.silo(
      id: id,
      kind: kind,
      title: title,
      titleSort: _string(json['sort_title']),
      summary: _string(json['overview']),
      tagline: _string(json['tagline']),
      originalTitle: _string(json['original_title']),
      studio: studios?.first,
      year: flexibleInt(json['year']),
      originallyAvailableAt:
          _string(json['release_date']) ?? _string(json['first_air_date']) ?? _string(json['air_date']),
      contentRating: _string(json['content_rating']),
      parentId: parentId,
      parentTitle: parentTitle,
      parentThumbPath: parentThumbPath,
      parentIndex: parentIndex,
      index: index,
      grandparentId: grandparentId,
      grandparentTitle: grandparentTitle,
      grandparentThumbPath: grandparentThumbPath,
      grandparentArtPath: grandparentArtPath,
      thumbPath: thumbPath,
      artPath: backdrop,
      backdropPaths: backdrop == null ? null : [backdrop],
      clearLogoPath: logo,
      durationMs: durationMs,
      viewOffsetMs: positionSeconds == null || positionSeconds <= 0 || played ? null : (positionSeconds * 1000).round(),
      viewCount: played ? (flexibleInt(userData?['watched_count']) ?? 1) : 0,
      lastViewedAt: _epochSeconds(json['progress_updated_at']) ?? _epochSeconds(userData?['last_played_at']),
      leafCount: kind == MediaKind.show || kind == MediaKind.season ? episodeCount : null,
      viewedLeafCount: viewedLeaf,
      childCount: flexibleInt(json['season_count']),
      addedAt: _epochSeconds(json['added_at']),
      rating: ratings?.first.value,
      userRating: _double(json['user_rating']) == null ? null : _double(json['user_rating'])! * 2,
      ratings: ratings,
      isFavorite: userState?['is_favorite'] == true,
      genres: genres,
      directors: _crew(json['crew'], (job) => job == 'director'),
      writers: _crew(json['crew'], (job) => job == 'writer' || job == 'screenplay'),
      producers: _crew(json['crew'], (job) => job == 'producer'),
      countries: _strings(json['countries']),
      roles: _cast(json['cast'], ctx),
      mediaVersions: _versions(json),
      libraryId: libraryId ?? _string(json['library_id']),
      libraryTitle: libraryTitle,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: json,
    );
  }

  static List<MediaItem> items(
    Iterable<Object?> list,
    SiloMappingContext ctx, {
    String? libraryId,
    String? libraryTitle,
  }) => list
      .whereType<Map<String, dynamic>>()
      .map((json) => item(json, ctx, libraryId: libraryId, libraryTitle: libraryTitle))
      .nonNulls
      .toList();

  /// Chapters of a detail or watch version, in milliseconds.
  static List<MediaChapter> chapters(Object? list, SiloMappingContext ctx) {
    if (list is! List) return [];
    final out = <MediaChapter>[];
    var position = 0;
    for (final entry in list.whereType<Map>()) {
      final start = _secondsToMs(entry['start_seconds']);
      out.add(
        MediaChapter(
          id: flexibleInt(entry['index']) ?? position,
          index: flexibleInt(entry['index']) ?? position,
          startTimeOffset: start,
          endTimeOffset: _secondsToMs(entry['end_seconds']),
          title: _string(entry['title']),
          thumb: _url(entry['thumbnail_url'], ctx),
        ),
      );
      position++;
    }
    return out;
  }

  /// Skip markers from a watch-detail version's `marker_segments`, falling
  /// back to the item-level `intro`/`credits`/`recap` objects (`{start,end}`
  /// on catalog detail, `{start_seconds,end_seconds}` on watch detail).
  static List<MediaMarker> markers(Map<String, dynamic>? item, Map<String, dynamic>? version) {
    final out = <MediaMarker>[];
    var id = 0;
    void add(String? kind, Object? start, Object? end) {
      final startMs = _secondsToMs(start);
      final endMs = _secondsToMs(end);
      if (kind == null || startMs == null || endMs == null || endMs <= startMs) return;
      out.add(MediaMarker(id: id++, type: kind, startTimeOffset: startMs, endTimeOffset: endMs));
    }

    final segments = version?['marker_segments'];
    if (segments is List && segments.isNotEmpty) {
      for (final segment in segments.whereType<Map>()) {
        add(_string(segment['kind']), segment['start_seconds'], segment['end_seconds']);
      }
      return out;
    }
    for (final source in [version, item].nonNulls) {
      for (final kind in const ['intro', 'credits', 'recap', 'preview']) {
        final marker = source[kind];
        if (marker is Map) {
          add(kind, marker['start_seconds'] ?? marker['start'], marker['end_seconds'] ?? marker['end']);
        }
      }
      if (out.isNotEmpty) return out;
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Watch detail (`GET /api/v2/watch/{id}`)
  // ---------------------------------------------------------------------------

  static List<Map<String, dynamic>> watchVersions(Map<String, dynamic>? watch) {
    final list = watch?['versions'];
    return list is List ? list.whereType<Map<String, dynamic>>().toList() : const [];
  }

  /// The caller's version (by file id, signature, then index), else the
  /// last one played, else the first.
  static int selectVersionIndex(
    List<Map<String, dynamic>> versions,
    Map<String, dynamic>? watch, {
    int? requestedIndex,
    String? requestedFileId,
    String? preferredSignature,
  }) {
    if (versions.isEmpty) return -1;
    if (requestedFileId != null) {
      final byId = versions.indexWhere((v) => v['file_id']?.toString() == requestedFileId);
      if (byId >= 0) return byId;
    }
    if (preferredSignature != null) {
      final mapped = versions.map(version).toList();
      for (var i = 0; i < mapped.length; i++) {
        if (mapped[i]?.signature == preferredSignature) return i;
      }
    }
    if (requestedIndex != null && requestedIndex >= 0 && requestedIndex < versions.length) return requestedIndex;
    final userData = watch?['user_data'];
    final last = userData is Map ? userData['last_file_id']?.toString() : null;
    if (last != null) {
      final byLast = versions.indexWhere((v) => v['file_id']?.toString() == last);
      if (byLast >= 0) return byLast;
    }
    return 0;
  }

  /// Audio/subtitle track ids are Silo's per-type index + 1, so no track has
  /// id 0.
  static int trackId(int index) => index + 1;

  static MediaSourceInfo sourceInfo(
    Map<String, dynamic> version, {
    required String videoUrl,
    required int mediaIndex,
    required SiloMappingContext ctx,
    int? selectedAudioIndex,
    Set<int> sidecarSubtitleIndexes = const {},
  }) {
    final audio = <MediaAudioTrack>[];
    final rawAudio = version['audio_tracks'];
    if (rawAudio is List) {
      var position = 0;
      for (final track in rawAudio.whereType<Map>()) {
        final index = (track['index'] as num?)?.toInt() ?? position;
        final isDefault = track['default'] == true;
        audio.add(
          MediaAudioTrack(
            id: trackId(index),
            index: index,
            codec: track['codec']?.toString(),
            language: track['language']?.toString(),
            languageCode: track['language']?.toString(),
            title: track['title']?.toString(),
            channels: (track['channels'] as num?)?.toInt(),
            selected: selectedAudioIndex == null ? isDefault : selectedAudioIndex == index,
            isDefault: isDefault,
          ),
        );
        position++;
      }
    }
    final subs = <MediaSubtitleTrack>[];
    final rawSubs = version['subtitle_tracks'];
    if (rawSubs is List) {
      var position = 0;
      for (final track in rawSubs.whereType<Map>()) {
        final index = (track['index'] as num?)?.toInt() ?? position;
        subs.add(
          MediaSubtitleTrack(
            id: trackId(index),
            index: index,
            codec: track['codec']?.toString(),
            language: track['language']?.toString(),
            languageCode: track['language']?.toString(),
            title: track['title']?.toString(),
            selected: false,
            forced: track['forced'] == true,
            external: track['external'] == true,
            usesExternalDelivery: sidecarSubtitleIndexes.contains(index),
          ),
        );
        position++;
      }
    }
    final defaultAudio = audio.where((a) => a.isDefault).firstOrNull;
    return MediaSourceInfo(
      videoUrl: videoUrl,
      audioTracks: audio,
      subtitleTracks: subs,
      chapters: MediaChapter.backfillEndOffsets(
        chapters(version['chapters'], ctx),
        runtimeMs: version['duration'] is num ? ((version['duration'] as num) * 1000).round() : null,
      ),
      mediaSourceId: version['file_id']?.toString(),
      mediaIndex: mediaIndex,
      defaultAudioStreamIndex: defaultAudio?.id,
    );
  }

  /// Chapters and skip markers of the version [selectVersionIndex] picks
  /// from a watch-detail payload.
  static PlaybackExtras playbackExtras(
    Map<String, dynamic>? watch,
    SiloMappingContext ctx, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) {
    final versions = watchVersions(watch);
    final selected = versions.isEmpty ? null : versions[selectVersionIndex(versions, watch)];
    final chapterList = selected == null ? <MediaChapter>[] : chapters(selected['chapters'], ctx);
    return PlaybackExtras.withChapterFallback(
      chapters: MediaChapter.backfillEndOffsets(chapterList),
      markers: markers(watch, selected),
      introPatternStr: introPattern,
      creditsPatternStr: creditsPattern,
      forceChapterFallback: forceChapterFallback,
    );
  }
}
