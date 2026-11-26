import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_part.dart';
import '../../media/media_rating.dart';
import '../../media/media_role.dart';
import '../../media/media_stream.dart';
import '../../media/media_version.dart';
import '../../utils/json_utils.dart';

/// Tofa ticks are 100 ns: 10,000 per millisecond.
const int tofaTicksPerMillisecond = 10000;

/// [duration] in Tofa ticks.
int tofaTicksFromDuration(Duration duration) => duration.inMicroseconds * 10;

/// Tofa [ticks] as a [Duration] (sub-microsecond ticks are dropped).
Duration tofaDurationFromTicks(int ticks) => Duration(microseconds: ticks ~/ 10);

/// What the mappers need from the client.
class TofaMappingContext {
  final String serverId;
  final String? serverName;
  const TofaMappingContext({required this.serverId, this.serverName});
}

/// Keys under [MediaItem.raw] of a [TofaMediaItem].
abstract final class TofaRaw {
  /// The title (movie or series) id: what `/media/{id}` takes.
  static const mediaId = 'tofa_media_id';
  static const seasonId = 'tofa_season_id';
  static const episodeId = 'tofa_episode_id';
  static const seasonNumber = 'tofa_season_number';
  static const episodeNumber = 'tofa_episode_number';

  /// A collection's `kind` (`franchise`, `curated`; `custom` for custom ones).
  static const collectionKind = 'tofa_collection_kind';

  /// The item's playable file ids (`MediaFile.id`), in the server's order.
  /// Order is presentation only: a file is picked by id.
  static const fileIds = 'tofa_file_ids';
  static const tmdbId = 'tmdb_id';
  static const imdbId = 'imdb_id';

  /// Continue Watching's file id, the one playback resumes.
  static const resumeFileId = 'tofa_resume_file_id';
}

/// Maps Tofa's `/api/v1` JSON onto Plezilo's neutral models.
///
/// **Item ids.** Titles keep Tofa's media id. Seasons and episodes have ids
/// of their own that `/media/{id}` does not take, so their item ids name the
/// title too: `tofa-season:{mediaId}/{seasonId}` and
/// `tofa-episode:{mediaId}/{episodeId}`. Tofa ids are opaque strings; one
/// containing `/` would not round-trip (none seen in the spec's examples,
/// which use UUID-like ids; unverified).
///
/// **Artwork.** `poster_path` / `backdrop_path` / `logo_path` are not
/// documented as paths or URLs (unverified), so titles are drawn through the
/// documented route `/api/v1/artwork/{media_id}/{kind}`: the item holds
/// `tofa-artwork:{mediaId}/{kind}` and `TofaClient.thumbnailUrl` adds the
/// server, the image token and the size. Episode stills and season posters
/// have no such route; they are used only when the server sends an absolute
/// `http(s)` URL, else the series' artwork stands in.
abstract final class TofaMappers {
  static const seasonPrefix = 'tofa-season:';
  static const episodePrefix = 'tofa-episode:';
  static const artworkScheme = 'tofa-artwork:';

  static String seasonItemId(String mediaId, String seasonId) => '$seasonPrefix$mediaId/$seasonId';
  static String episodeItemId(String mediaId, String episodeId) => '$episodePrefix$mediaId/$episodeId';

  /// `(mediaId, seasonId)` of a season item id, or null.
  static ({String mediaId, String childId})? parseSeasonId(String id) => _parseChild(id, seasonPrefix);

  /// `(mediaId, episodeId)` of an episode item id, or null.
  static ({String mediaId, String childId})? parseEpisodeId(String id) => _parseChild(id, episodePrefix);

  static ({String mediaId, String childId})? _parseChild(String id, String prefix) {
    if (!id.startsWith(prefix)) return null;
    final rest = id.substring(prefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return null;
    return (mediaId: rest.substring(0, slash), childId: rest.substring(slash + 1));
  }

  /// The title id an item id belongs to (itself for a movie or series).
  static String mediaIdOf(String itemId) => parseSeasonId(itemId)?.mediaId ?? parseEpisodeId(itemId)?.mediaId ?? itemId;

  static String artworkPath(String mediaId, String kind) => '$artworkScheme$mediaId/$kind';

  /// `(mediaId, kind)` of an [artworkPath], or null.
  static ({String mediaId, String kind})? parseArtworkPath(String path) {
    if (!path.startsWith(artworkScheme)) return null;
    final rest = path.substring(artworkScheme.length);
    final slash = rest.lastIndexOf('/');
    if (slash <= 0) return null;
    final kind = rest.substring(slash + 1);
    if (!const {'poster', 'backdrop', 'backdrop_thumb', 'logo'}.contains(kind)) return null;
    return (mediaId: rest.substring(0, slash), kind: kind);
  }

  static String? _string(Object? v) => v is String && v.isNotEmpty ? v : (v is num ? v.toString() : null);

  static String? _absoluteUrl(Object? v) {
    final s = _string(v);
    return s != null && (s.startsWith('https://') || s.startsWith('http://')) ? s : null;
  }

  static int? _year(Object? date) {
    final s = _string(date);
    if (s == null || s.length < 4) return null;
    return int.tryParse(s.substring(0, 4));
  }

  static List<String>? _strings(Object? raw) {
    if (raw is! List) return null;
    final out = [for (final v in raw) ?_string(v)];
    return out.isEmpty ? null : out;
  }

  static int? _epochSeconds(Object? iso) {
    final s = _string(iso);
    final parsed = s == null ? null : DateTime.tryParse(s);
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  /// `media_type` → kind. `other` titles (home videos and the like) carry
  /// their own files like a movie, so they play as one.
  static MediaKind kindOf(Object? mediaType) => switch (mediaType) {
    'tv' => MediaKind.show,
    'movie' || 'other' => MediaKind.movie,
    _ => MediaKind.unknown,
  };

  static List<MediaRatingSource>? _ratings(Map<String, dynamic> json) {
    final out = [
      ?MediaRatingSource.fromScale('imdb', flexibleDouble(json['imdb_rating']), scale: 10),
      ?MediaRatingSource.fromScale('rottenTomatoesCritic', flexibleDouble(json['rotten_tomatoes_score']), scale: 100),
      ?MediaRatingSource.fromScale(
        'rottenTomatoesAudience',
        flexibleDouble(json['rotten_tomatoes_audience_score']),
        scale: 100,
      ),
      ?MediaRatingSource.fromScale('metacritic', flexibleDouble(json['metacritic_score']), scale: 100),
    ];
    return out.isEmpty ? null : out;
  }

  /// One library (`LibraryResponse`).
  static MediaLibrary? library(Map<String, dynamic> json, TofaMappingContext ctx) {
    final id = _string(json['id']);
    final name = _string(json['name']);
    if (id == null || name == null) return null;
    final kind = switch (json['library_kind'] ?? json['media_type']) {
      'movie' => MediaKind.movie,
      'tv' => MediaKind.show,
      _ => MediaKind.unknown,
    };
    return MediaLibrary(
      id: id,
      backend: MediaBackend.tofa,
      title: name,
      kind: kind,
      defaultBrowseKinds: kind == MediaKind.unknown ? const [MediaKind.movie, MediaKind.show] : const [],
      createdAt: _epochSeconds(json['created_at']),
      updatedAt: _epochSeconds(json['updated_at']),
      serverId: ctx.serverId,
      serverName: ctx.serverName,
    );
  }

  /// Whether a list row (`MediaSummary`) is watched.
  static bool summaryWatched(Map<String, dynamic> json) {
    if (json['watched'] == true) return true;
    final mark = json['watch_mark'];
    return mark is Map && mark['state'] == 'watched';
  }

  /// A list row (`MediaSummary`, also search hits and similar titles).
  static TofaMediaItem? summary(Map<String, dynamic> json, TofaMappingContext ctx, {String? libraryTitle}) {
    final id = _string(json['id']);
    final title = _string(json['title']);
    if (id == null || title == null) return null;
    final kind = kindOf(json['media_type']);
    if (kind == MediaKind.unknown) return null;
    final runtime = flexibleInt(json['runtime_minutes']);
    final mark = json['watch_mark'];
    final watched = summaryWatched(json);
    final unwatchedEpisodes =
        flexibleInt(json['unwatched_episode_count']) ??
        (mark is Map && mark['state'] == 'episodes_left' ? flexibleInt(mark['episodes_left']) : null);
    final progressPercent = mark is Map ? flexibleInt(mark['progress_percent']) : null;
    final durationMs = runtime == null || runtime <= 0 ? null : runtime * 60000;
    return TofaMediaItem(
      id: id,
      kind: kind,
      title: title,
      summary: _string(json['overview']),
      year: _year(json['release_date']),
      originallyAvailableAt: _string(json['release_date']),
      contentRating: _string(json['content_rating']),
      thumbPath: json['poster_path'] != null ? artworkPath(id, 'poster') : null,
      artPath: json['backdrop_path'] != null ? artworkPath(id, 'backdrop') : null,
      clearLogoPath: json['logo_path'] != null ? artworkPath(id, 'logo') : null,
      durationMs: durationMs,
      viewCount: watched ? 1 : 0,
      // A movie part-way through: Tofa gives the percentage only.
      viewOffsetMs: kind == MediaKind.movie && !watched && progressPercent != null && durationMs != null
          ? durationMs * progressPercent ~/ 100
          : null,
      // Series rows say only how many episodes are left (no total), so that
      // count stands in as the total with none viewed: the card's unwatched
      // badge shows it, and a series with none left falls back to viewCount.
      leafCount: kind == MediaKind.show && (unwatchedEpisodes ?? 0) > 0 ? unwatchedEpisodes : null,
      viewedLeafCount: kind == MediaKind.show && (unwatchedEpisodes ?? 0) > 0 ? 0 : null,
      rating: flexibleDouble(json['rating']),
      ratings: _ratings(json),
      genres: _strings(json['genres']),
      libraryId: _string(json['library_id']),
      libraryTitle: libraryTitle,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {TofaRaw.mediaId: id, TofaRaw.tmdbId: ?flexibleInt(json['tmdb_id'])},
    );
  }

  /// One file (`MediaFile`) as a version. Files after the first part of a
  /// multi-part set are not versions of their own (see [playableFiles]).
  static MediaVersion? version(Map<String, dynamic> file) {
    final id = _string(file['id']);
    if (id == null) return null;
    final height = flexibleInt(file['height']);
    final streams = <MediaStream>[
      if (_string(file['video_codec']) case final codec?)
        MediaStream(
          id: '$id:v',
          kind: MediaStreamKind.video,
          codec: codec,
          frameRate: flexibleDouble(file['display_frame_rate']),
          hdr: file['hdr'] == true,
          dolbyVision: flexibleInt(file['dolby_vision_profile']) != null,
          dolbyVisionProfile: flexibleInt(file['dolby_vision_profile']),
        ),
      for (final track in (file['audio_tracks'] is List ? file['audio_tracks'] as List : const []).whereType<Map>())
        MediaStream(
          id: '$id:a${track['index']}',
          kind: MediaStreamKind.audio,
          index: flexibleInt(track['index']),
          codec: _string(track['codec']),
          language: _string(track['language']),
          languageCode: _string(track['language']),
          title: _string(track['title']),
          channels: flexibleInt(track['channels']),
        ),
      for (final track
          in (file['subtitle_tracks'] is List ? file['subtitle_tracks'] as List : const []).whereType<Map>())
        MediaStream(
          id: '$id:s${track['index']}',
          kind: MediaStreamKind.subtitle,
          index: flexibleInt(track['index']),
          codec: _string(track['codec']),
          language: _string(track['language']),
          languageCode: _string(track['language']),
          title: _string(track['title']),
          forced: track['forced'] == true,
          isDefault: track['default_disposition'] == true,
        ),
    ];
    return MediaVersion(
      id: id,
      height: height,
      videoResolution: _string(file['resolution']) ?? (height == null ? null : '$height'),
      videoCodec: _string(file['video_codec']),
      bitrate: bitrateKbpsFromBps(flexibleInt(file['bitrate'])),
      container: _string(file['container']),
      name: _string(file['edition']),
      parts: [
        MediaPart(
          id: id,
          container: _string(file['container']),
          sizeBytes: flexibleInt(file['file_size']),
          durationMs: flexibleInt(file['duration_ms']),
          accessible: file['available'] == false ? false : null,
          streams: streams,
        ),
      ],
    );
  }

  /// The files a title or episode can start: available ones that are not a
  /// later part of a multi-part set (Plezilo plays one file per version; the
  /// later parts of a cd1/cd2 movie are a follow-up).
  static List<Map<String, dynamic>> playableFiles(Object? files) {
    if (files is! List) return const [];
    return [
      for (final file in files.whereType<Map<String, dynamic>>())
        if (_string(file['id']) != null &&
            file['available'] != false &&
            (flexibleInt(file['part_number']) == null || flexibleInt(file['part_number']) == 1))
          file,
    ];
  }

  static int? _filesDurationMs(List<Map<String, dynamic>> files) {
    for (final file in files) {
      final ms = flexibleInt(file['duration_ms']);
      if (ms != null && ms > 0) return ms;
    }
    return null;
  }

  static String? _providerId(Object? providerIds, String provider) {
    if (providerIds is! List) return null;
    for (final row in providerIds.whereType<Map>()) {
      if (row['provider'] == provider) return _string(row['provider_id']);
    }
    return null;
  }

  static List<MediaRole>? _roles(Object? cast) {
    if (cast is! List) return null;
    final out = [
      for (final member in cast.whereType<Map>())
        if (_string(member['name']) case final name?)
          MediaRole(tag: name, role: _string(member['role']), thumbPath: _absoluteUrl(member['profile_url'])),
    ];
    return out.isEmpty ? null : out;
  }

  static List<String>? _crew(Object? crew, String job) {
    if (crew is! List) return null;
    final out = [
      for (final member in crew.whereType<Map>())
        if ((member['job'] == job || member['department'] == job) && _string(member['name']) != null)
          _string(member['name'])!,
    ];
    return out.isEmpty ? null : out;
  }

  /// Watch state of the files of one movie or episode, from
  /// `/media/progress/batch` rows keyed by file id.
  static ({bool watched, int? offsetMs, int? lastViewedAt}) fileWatchState(
    Iterable<String> fileIds,
    Map<String, Map<String, dynamic>> progress,
  ) {
    var watched = false;
    int? offset;
    int? lastViewed;
    int? lastOffsetAt;
    for (final id in fileIds) {
      final row = progress[id];
      if (row == null) continue;
      final at = _epochSeconds(row['last_watched_at'] ?? row['updated_at']);
      if (at != null && (lastViewed == null || at > lastViewed)) lastViewed = at;
      if (row['completed'] == true) {
        watched = true;
        continue;
      }
      final position = flexibleInt(row['position_ms']);
      if (position != null && position > 0 && (lastOffsetAt == null || (at ?? 0) >= lastOffsetAt)) {
        offset = position;
        lastOffsetAt = at ?? 0;
      }
    }
    return (watched: watched, offsetMs: watched ? null : offset, lastViewedAt: lastViewed);
  }

  /// A title's detail (`MediaDetail`) as its item; with [progress] (file id →
  /// `WatchProgressResponse`) its watch state too. A series' leaf counts
  /// cover the episodes of every season but specials (season 0).
  static TofaMediaItem? detail(
    Map<String, dynamic> json,
    TofaMappingContext ctx, {
    Map<String, Map<String, dynamic>> progress = const {},
    String? libraryTitle,
  }) {
    final id = _string(json['id']);
    final title = _string(json['title']);
    if (id == null || title == null) return null;
    final kind = kindOf(json['media_type']);
    if (kind == MediaKind.unknown) return null;
    final files = playableFiles(json['files']);
    final runtime = flexibleInt(json['runtime_minutes']);
    final fileIds = [for (final f in files) f['id'] as String];
    final state = fileWatchState(fileIds, progress);
    int? leafCount;
    int? viewedLeafCount;
    int? childCount;
    if (kind == MediaKind.show) {
      final seasons = json['seasons'] is List ? (json['seasons'] as List).whereType<Map<String, dynamic>>() : null;
      if (seasons != null) {
        childCount = seasons.length;
        leafCount = 0;
        viewedLeafCount = 0;
        for (final season in seasons) {
          if (flexibleInt(season['season_number']) == 0) continue;
          for (final episode
              in (season['episodes'] is List ? season['episodes'] as List : const [])
                  .whereType<Map<String, dynamic>>()) {
            leafCount = leafCount! + 1;
            final ids = [for (final f in playableFiles(episode['files'])) f['id'] as String];
            if (fileWatchState(ids, progress).watched) viewedLeafCount = viewedLeafCount! + 1;
          }
        }
      }
    }
    final studios = _strings(json['studios']);
    final durationMs = _filesDurationMs(files) ?? (runtime == null || runtime <= 0 ? null : runtime * 60000);
    return TofaMediaItem(
      id: id,
      kind: kind,
      title: title,
      titleSort: _string(json['sort_title']),
      originalTitle: _string(json['original_title']),
      summary: _string(json['overview']),
      tagline: _string(json['tagline']),
      studio: studios?.first,
      year: _year(json['release_date']),
      originallyAvailableAt: _string(json['release_date']),
      contentRating: _string(json['content_rating']),
      thumbPath: json['poster_path'] != null ? artworkPath(id, 'poster') : null,
      artPath: json['backdrop_path'] != null ? artworkPath(id, 'backdrop') : null,
      clearLogoPath: json['logo_path'] != null ? artworkPath(id, 'logo') : null,
      durationMs: durationMs,
      viewCount: kind == MediaKind.show
          ? (leafCount != null && leafCount > 0 && viewedLeafCount == leafCount ? 1 : 0)
          : (state.watched ? 1 : 0),
      viewOffsetMs: kind == MediaKind.movie ? state.offsetMs : null,
      lastViewedAt: state.lastViewedAt,
      leafCount: leafCount,
      viewedLeafCount: viewedLeafCount,
      childCount: childCount,
      addedAt: _epochSeconds(json['added_at']),
      updatedAt: _epochSeconds(json['updated_at']),
      rating: flexibleDouble(json['rating']),
      ratings: _ratings(json),
      genres: _strings(json['genres']),
      countries: _strings(json['countries']),
      labels: _strings(json['tags']),
      roles: _roles(json['cast']),
      directors: _crew(json['crew'], 'Director'),
      writers: _crew(json['crew'], 'Writer'),
      mediaVersions: kind == MediaKind.movie ? [for (final f in files) ?version(f)] : null,
      libraryId: _string(json['library_id']),
      libraryTitle: libraryTitle,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {
        TofaRaw.mediaId: id,
        if (kind == MediaKind.movie) TofaRaw.fileIds: fileIds,
        TofaRaw.tmdbId: ?flexibleInt(json['tmdb_id']),
        TofaRaw.imdbId: ?(_string(json['imdb_id']) ?? _providerId(json['provider_ids'], 'imdb')),
        'tvdb_id': ?_providerId(json['provider_ids'], 'tvdb'),
        'youtube_trailer_id': ?_string(json['youtube_trailer_id']),
      },
    );
  }

  /// The seasons of a series detail, in season order (specials, season 0,
  /// last), each with its episodes' watch state from [progress].
  static List<TofaMediaItem> seasons(
    Map<String, dynamic> json,
    TofaMediaItem show,
    TofaMappingContext ctx, {
    Map<String, Map<String, dynamic>> progress = const {},
  }) {
    final raw = json['seasons'];
    if (raw is! List) return const [];
    final out = <TofaMediaItem>[];
    for (final season in raw.whereType<Map<String, dynamic>>()) {
      final item = TofaMappers.season(season, show, ctx, progress: progress);
      if (item != null) out.add(item);
    }
    out.sort(_bySeasonNumber);
    return out;
  }

  static int _bySeasonNumber(MediaItem a, MediaItem b) {
    final x = a.index ?? 0;
    final y = b.index ?? 0;
    if (x == 0 && y != 0) return 1;
    if (y == 0 && x != 0) return -1;
    return x.compareTo(y);
  }

  static TofaMediaItem? season(
    Map<String, dynamic> season,
    TofaMediaItem show,
    TofaMappingContext ctx, {
    Map<String, Map<String, dynamic>> progress = const {},
  }) {
    final seasonId = _string(season['id']);
    final number = flexibleInt(season['season_number']);
    if (seasonId == null || number == null) return null;
    final episodes = season['episodes'] is List
        ? (season['episodes'] as List).whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
    var viewed = 0;
    for (final episode in episodes) {
      final ids = [for (final f in playableFiles(episode['files'])) f['id'] as String];
      if (fileWatchState(ids, progress).watched) viewed++;
    }
    return TofaMediaItem(
      id: seasonItemId(show.id, seasonId),
      kind: MediaKind.season,
      title: _string(season['title']),
      summary: _string(season['overview']),
      year: _year(season['air_date']),
      originallyAvailableAt: _string(season['air_date']),
      index: number,
      parentId: show.id,
      parentTitle: show.title,
      parentThumbPath: show.thumbPath,
      thumbPath: _absoluteUrl(season['poster_path']) ?? show.thumbPath,
      artPath: show.artPath,
      leafCount: episodes.length,
      viewedLeafCount: viewed,
      viewCount: episodes.isNotEmpty && viewed == episodes.length ? 1 : 0,
      libraryId: show.libraryId,
      libraryTitle: show.libraryTitle,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {TofaRaw.mediaId: show.id, TofaRaw.seasonId: seasonId, TofaRaw.seasonNumber: number},
    );
  }

  /// The episodes of [seasonJson] (a `SeasonWithEpisodes`), in episode order.
  static List<TofaMediaItem> episodes(
    Map<String, dynamic> seasonJson,
    TofaMediaItem show,
    TofaMappingContext ctx, {
    Map<String, Map<String, dynamic>> progress = const {},
  }) {
    final seasonId = _string(seasonJson['id']);
    final number = flexibleInt(seasonJson['season_number']);
    final raw = seasonJson['episodes'];
    if (seasonId == null || number == null || raw is! List) return const [];
    final out = [
      for (final episode in raw.whereType<Map<String, dynamic>>())
        ?TofaMappers.episode(
          episode,
          show: show,
          seasonId: seasonId,
          seasonNumber: number,
          seasonTitle: _string(seasonJson['title']),
          ctx: ctx,
          progress: progress,
        ),
    ];
    out.sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));
    return out;
  }

  static TofaMediaItem? episode(
    Map<String, dynamic> json, {
    required TofaMediaItem show,
    required String seasonId,
    required int seasonNumber,
    String? seasonTitle,
    required TofaMappingContext ctx,
    Map<String, Map<String, dynamic>> progress = const {},
  }) {
    final episodeId = _string(json['id']);
    final number = flexibleInt(json['episode_number']);
    if (episodeId == null || number == null) return null;
    final files = playableFiles(json['files']);
    final fileIds = [for (final f in files) f['id'] as String];
    final state = fileWatchState(fileIds, progress);
    final runtime = flexibleInt(json['runtime_minutes']);
    return TofaMediaItem(
      id: episodeItemId(show.id, episodeId),
      kind: MediaKind.episode,
      title: _string(json['title']),
      summary: _string(json['overview']),
      year: _year(json['air_date']),
      originallyAvailableAt: _string(json['air_date']),
      index: number,
      parentIndex: seasonNumber,
      parentId: seasonItemId(show.id, seasonId),
      parentTitle: seasonTitle,
      parentThumbPath: show.thumbPath,
      grandparentId: show.id,
      grandparentTitle: show.title,
      grandparentThumbPath: show.thumbPath,
      grandparentArtPath: show.artPath,
      thumbPath: _absoluteUrl(json['still_path']) ?? artworkPath(show.id, 'backdrop_thumb'),
      artPath: show.artPath,
      durationMs: _filesDurationMs(files) ?? (runtime == null || runtime <= 0 ? null : runtime * 60000),
      viewCount: state.watched ? 1 : 0,
      viewOffsetMs: state.offsetMs,
      lastViewedAt: state.lastViewedAt,
      contentRating: show.contentRating,
      mediaVersions: [for (final f in files) ?version(f)],
      libraryId: show.libraryId,
      libraryTitle: show.libraryTitle,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {
        TofaRaw.mediaId: show.id,
        TofaRaw.seasonId: seasonId,
        TofaRaw.episodeId: episodeId,
        TofaRaw.seasonNumber: seasonNumber,
        TofaRaw.episodeNumber: number,
        TofaRaw.fileIds: fileIds,
      },
    );
  }

  /// A Continue Watching row (`ContinueWatchingItem`): the movie, or the
  /// episode to resume or watch next.
  static TofaMediaItem? continueWatching(Map<String, dynamic> json, TofaMappingContext ctx) {
    final mediaId = _string(json['media_id']);
    final fileId = _string(json['media_file_id']);
    final title = _string(json['title']);
    if (mediaId == null || fileId == null || title == null) return null;
    final episodeId = _string(json['episode_id']);
    final position = flexibleInt(json['position_ms']);
    final duration = flexibleInt(json['duration_ms']);
    final resume = json['kind'] == 'resume' && position != null && position > 0 ? position : null;
    final updatedAt = _epochSeconds(json['updated_at']);
    final common = (
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      duration: duration != null && duration > 0 ? duration : null,
    );
    if (episodeId == null) {
      return TofaMediaItem(
        id: mediaId,
        kind: MediaKind.movie,
        title: title,
        summary: _string(json['overview']),
        year: flexibleInt(json['year']),
        contentRating: _string(json['content_rating']),
        thumbPath: json['poster_path'] != null ? artworkPath(mediaId, 'poster') : null,
        artPath: json['backdrop_path'] != null ? artworkPath(mediaId, 'backdrop') : null,
        clearLogoPath: json['logo_path'] != null ? artworkPath(mediaId, 'logo') : null,
        durationMs: common.duration,
        viewOffsetMs: resume,
        viewCount: 0,
        lastViewedAt: updatedAt,
        genres: _strings(json['genres']),
        serverId: common.serverId,
        serverName: common.serverName,
        raw: {TofaRaw.mediaId: mediaId, TofaRaw.resumeFileId: fileId, MediaItem.continueWatchingRecencyKey: ?updatedAt},
      );
    }
    final seasonId = _string(json['season_id']);
    final seasonNumber = flexibleInt(json['season_number']);
    final showPoster = json['poster_path'] != null ? artworkPath(mediaId, 'poster') : null;
    final showArt = json['backdrop_path'] != null ? artworkPath(mediaId, 'backdrop') : null;
    return TofaMediaItem(
      id: episodeItemId(mediaId, episodeId),
      kind: MediaKind.episode,
      title: _string(json['episode_title']),
      summary: _string(json['overview']),
      originallyAvailableAt: _string(json['air_date']),
      index: flexibleInt(json['episode_number']),
      parentIndex: seasonNumber,
      parentId: seasonId == null ? null : seasonItemId(mediaId, seasonId),
      grandparentId: mediaId,
      grandparentTitle: title,
      grandparentThumbPath: showPoster,
      grandparentArtPath: showArt,
      thumbPath: json['backdrop_thumb'] != null ? artworkPath(mediaId, 'backdrop_thumb') : showArt,
      artPath: showArt,
      durationMs: common.duration,
      viewOffsetMs: resume,
      viewCount: 0,
      lastViewedAt: updatedAt,
      contentRating: _string(json['content_rating']),
      serverId: common.serverId,
      serverName: common.serverName,
      raw: {
        TofaRaw.mediaId: mediaId,
        TofaRaw.seasonId: ?seasonId,
        TofaRaw.episodeId: episodeId,
        TofaRaw.seasonNumber: ?seasonNumber,
        TofaRaw.episodeNumber: ?flexibleInt(json['episode_number']),
        TofaRaw.resumeFileId: fileId,
        TofaRaw.fileIds: [fileId],
        MediaItem.continueWatchingRecencyKey: ?updatedAt,
      },
    );
  }

  /// A Ready to Binge season (`BingeReadySeason`): the season of its series,
  /// with the series as its parent.
  static TofaMediaItem? bingeReadySeason(Map<String, dynamic> json, TofaMappingContext ctx) {
    final media = json['media'];
    final seasonId = _string(json['season_id']);
    final number = flexibleInt(json['season_number']);
    if (media is! Map<String, dynamic> || seasonId == null || number == null) return null;
    final show = summary(media, ctx);
    if (show == null || show.kind != MediaKind.show) return null;
    final episodes = flexibleInt(json['episode_count']);
    return TofaMediaItem(
      id: seasonItemId(show.id, seasonId),
      kind: MediaKind.season,
      title: _string(json['season_title']),
      index: number,
      parentId: show.id,
      parentTitle: show.title,
      parentThumbPath: show.thumbPath,
      thumbPath: _absoluteUrl(json['season_poster_path']) ?? show.thumbPath,
      artPath: show.artPath,
      leafCount: episodes,
      viewedLeafCount: episodes == null ? null : 0,
      viewCount: 0,
      libraryId: show.libraryId,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {TofaRaw.mediaId: show.id, TofaRaw.seasonId: seasonId, TofaRaw.seasonNumber: number},
    );
  }

  /// A watchlist entry (`WatchlistItem`) that is in the library (`owned`
  /// with a `media_id`); titles not in the library are left out.
  static TofaMediaItem? watchlistItem(Map<String, dynamic> json, TofaMappingContext ctx) {
    final mediaId = _string(json['media_id']);
    if (json['owned'] != true || mediaId == null) return null;
    final type = json['media_type'] ?? json['media_kind'];
    return summary({
      ...json,
      'id': mediaId,
      'media_type': type == 'show' || type == 'series' ? 'tv' : type,
      'release_date': json['year'] == null ? null : '${json['year']}-01-01',
    }, ctx);
  }

  // ---------------------------------------------------------------------------
  // Collections
  // ---------------------------------------------------------------------------

  /// Franchise and curated collections (`GET /collections`, `CollectionSummary`).
  static const collectionPrefix = 'tofa-collection:';

  /// Custom collections and lists (`GET /collections/custom`), a separate
  /// id space with their own routes.
  static const customCollectionPrefix = 'tofa-custom:';

  static String collectionItemId(String id, {required bool custom}) =>
      '${custom ? customCollectionPrefix : collectionPrefix}$id';

  /// `(collectionId, custom)` of a collection item id, or null.
  static ({String id, bool custom})? parseCollectionId(String itemId) {
    for (final (prefix, custom) in [(collectionPrefix, false), (customCollectionPrefix, true)]) {
      if (itemId.startsWith(prefix) && itemId.length > prefix.length) {
        return (id: itemId.substring(prefix.length), custom: custom);
      }
    }
    return null;
  }

  /// Collection artwork. The spec gives `poster_url` / `backdrop_url` /
  /// `logo_url` (and custom collections' `poster_path` / `backdrop_path`) as
  /// strings without saying their form. Unverified: an absolute URL is used
  /// as it is and a server route (`/api/…`) is signed with the image token
  /// ([TofaClient.thumbnailUrl]); a bare file path is not guessed at.
  static String? collectionArt(Object? v) {
    final s = _string(v);
    if (s == null) return null;
    if (s.startsWith('https://') || s.startsWith('http://') || s.startsWith('/api/')) return s;
    return null;
  }

  /// One collection card: a `CollectionSummary`, `CollectionResponse`,
  /// `CustomCollectionSummary` or `CustomCollectionResponse`.
  static TofaMediaItem? collection(Map<String, dynamic> json, TofaMappingContext ctx, {required bool custom}) {
    final id = _string(json['id']);
    final name = _string(json['name']);
    if (id == null || name == null) return null;
    final count = flexibleInt(json['item_count']) ?? (json['items'] is List ? (json['items'] as List).length : null);
    return TofaMediaItem(
      id: collectionItemId(id, custom: custom),
      kind: MediaKind.collection,
      title: name,
      summary: _string(json['overview']),
      thumbPath: collectionArt(json['poster_url']) ?? collectionArt(json['poster_path']),
      artPath: collectionArt(json['backdrop_url']) ?? collectionArt(json['backdrop_path']),
      clearLogoPath: collectionArt(json['logo_url']),
      childCount: count,
      leafCount: count,
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {TofaRaw.collectionKind: ?_string(json['kind']) ?? (custom ? 'custom' : null)},
    );
  }

  /// A franchise or curated collection's member (`AnnotatedDiscoveryItem`):
  /// only titles in the library (`in_library` with `local_media_id`), as
  /// their library title; the rest cannot be played here.
  static TofaMediaItem? discoveryItem(Map<String, dynamic> json, TofaMappingContext ctx) {
    final localId = _string(json['local_media_id']);
    if (json['in_library'] != true || localId == null) return null;
    final type = json['type'] ?? json['media_type'];
    final year = flexibleInt(json['year']);
    return summary({
      ...json,
      'id': localId,
      'media_type': type == 'show' || type == 'series' ? 'tv' : type,
      'release_date': json['release_date'] ?? (year == null ? null : '$year-01-01'),
    }, ctx);
  }

  /// The playable file ids a mapped item carries.
  static List<String> fileIdsOf(MediaItem item) {
    final raw = item.raw?[TofaRaw.fileIds];
    return raw is List ? [for (final v in raw) ?_string(v)] : const [];
  }
}
