import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_part.dart';
import '../../media/media_role.dart';
import '../../media/media_version.dart';

/// Plezilo ids for tofa items.
///
/// Movies and shows use their tofa media id. tofa has no detail endpoint for
/// a season or an episode (they come nested in the show), so their Plezilo id
/// also names the show: `<showId>~s~<seasonId>` and `<showId>~e~<episodeId>`.
/// That keeps every id resolvable on its own, after a restart or offline.
class TofaIds {
  static const _season = '~s~';
  static const _episode = '~e~';

  static String season(String showId, String seasonId) => '$showId$_season$seasonId';
  static String episode(String showId, String episodeId) => '$showId$_episode$episodeId';

  /// Splits a Plezilo id into the show (or title) id and, for a season or an
  /// episode, its own tofa id.
  static ({String mediaId, String? seasonId, String? episodeId}) parse(String id) {
    final s = id.indexOf(_season);
    if (s > 0) return (mediaId: id.substring(0, s), seasonId: id.substring(s + _season.length), episodeId: null);
    final e = id.indexOf(_episode);
    if (e > 0) return (mediaId: id.substring(0, e), seasonId: null, episodeId: id.substring(e + _episode.length));
    return (mediaId: id, seasonId: null, episodeId: null);
  }
}

/// Raw-map keys the client reads back from mapped items.
abstract final class TofaRaw {
  /// The media file a movie or an episode plays.
  static const fileId = 'tofa_file_id';

  /// tofa's own id of a season or an episode.
  static const nativeId = 'tofa_id';
}

class TofaMappingContext {
  final String serverId;
  final String? serverName;
  final Map<String, String> libraryTitles;

  const TofaMappingContext({required this.serverId, this.serverName, this.libraryTitles = const {}});
}

int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
double? _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
String? _str(Object? v) {
  final s = v?.toString();
  return s == null || s.isEmpty ? null : s;
}

int? _yearOf(Object? date) {
  final s = _str(date);
  if (s == null || s.length < 4) return null;
  return int.tryParse(s.substring(0, 4));
}

int? _epochSeconds(Object? iso) {
  final s = _str(iso);
  if (s == null) return null;
  final parsed = DateTime.tryParse(s);
  return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
}

List<String>? _strings(Object? v) => v is List ? v.map((e) => e.toString()).toList() : null;

MediaKind _kindOf(Object? mediaType) => switch (mediaType) {
  'movie' => MediaKind.movie,
  'tv' => MediaKind.show,
  _ => MediaKind.movie,
};

/// The first available file of a movie or an episode, or the first file.
Map<String, dynamic>? primaryFile(Object? files) {
  if (files is! List) return null;
  final maps = files.whereType<Map<String, dynamic>>().toList();
  if (maps.isEmpty) return null;
  return maps.firstWhere((f) => f['available'] != false, orElse: () => maps.first);
}

/// Versions of a movie or an episode, one per available file.
List<MediaVersion> versionsOf(Object? files) {
  if (files is! List) return const [];
  return [
    for (final f in files.whereType<Map<String, dynamic>>())
      if (f['available'] != false)
        MediaVersion(
          id: f['id']?.toString() ?? '',
          width: _int(f['width']),
          height: _int(f['height']),
          videoResolution: _str(f['resolution']),
          videoCodec: _str(f['video_codec']),
          bitrate: _int(f['bitrate']),
          container: _str(f['container']),
          name: _str(f['edition']),
          parts: [
            MediaPart(
              id: f['id']?.toString() ?? '',
              container: _str(f['container']),
              durationMs: _int(f['duration_ms']),
              sizeBytes: _int(f['file_size']),
            ),
          ],
        ),
  ];
}

/// A `MediaSummary` (lists, search, rows) or a `MediaDetail` as a title.
MediaItem mapTitle(Map<String, dynamic> json, TofaMappingContext ctx) {
  final kind = _kindOf(json['media_type']);
  final file = kind == MediaKind.movie ? primaryFile(json['files']) : null;
  final watched = json['watched'] == true || (json['watch_mark'] is Map && json['watch_mark']['state'] == 'watched');
  final unwatched = _int(json['unwatched_episode_count']);
  final libraryId = _str(json['library_id']);
  final cast = json['cast'];
  final crew = json['crew'];
  return MediaItem.tofa(
    id: json['id']?.toString() ?? '',
    kind: kind,
    title: _str(json['title']),
    titleSort: _str(json['sort_title']),
    summary: _str(json['overview']),
    tagline: _str(json['tagline']),
    originalTitle: _str(json['original_title']),
    studio: (json['studios'] is List && (json['studios'] as List).isNotEmpty) ? json['studios'][0].toString() : null,
    year: _yearOf(json['release_date']),
    originallyAvailableAt: _str(json['release_date']),
    contentRating: _str(json['content_rating']),
    thumbPath: _str(json['poster_path']),
    artPath: _str(json['backdrop_path']),
    clearLogoPath: _str(json['logo_path']),
    durationMs: _int(file?['duration_ms']) ?? ((_int(json['runtime_minutes']) ?? 0) * 60000).nullIfZero,
    viewCount: watched ? 1 : 0,
    // A show's poster badge reads "N episodes left" from leaf counts.
    leafCount: kind == MediaKind.show && unwatched != null ? unwatched : null,
    viewedLeafCount: kind == MediaKind.show && unwatched != null ? 0 : null,
    addedAt: _epochSeconds(json['added_at']),
    rating: _double(json['rating']),
    genres: _strings(json['genres']),
    directors: crew is List
        ? [
            for (final c in crew.whereType<Map>())
              if ('${c['job'] ?? ''}'.toLowerCase() == 'director') '${c['name']}',
          ]
        : null,
    roles: cast is List
        ? [
            for (final c in cast.whereType<Map>())
              MediaRole(id: _str(c['person_id']), tag: '${c['name'] ?? ''}', role: _str(c['role']), thumbPath: _str(c['profile_url'])),
          ]
        : null,
    mediaVersions: kind == MediaKind.movie && json['files'] is List ? versionsOf(json['files']) : null,
    libraryId: libraryId,
    libraryTitle: libraryId == null ? null : ctx.libraryTitles[libraryId],
    serverId: ctx.serverId,
    serverName: ctx.serverName,
    raw: {
      TofaRaw.fileId: ?file?['id']?.toString(),
      if (_int(json['tmdb_id']) != null) 'tmdb_id': _int(json['tmdb_id']),
      if (_str(json['imdb_id']) != null) 'imdb_id': _str(json['imdb_id']),
      if (json['provider_ids'] is List) 'provider_ids': json['provider_ids'],
      if (json['next_up'] is Map) 'next_up': json['next_up'],
      'library_id': ?libraryId,
    },
  );
}

/// A season of [show] (`SeasonWithEpisodes`).
MediaItem mapSeason(Map<String, dynamic> season, MediaItem show, TofaMappingContext ctx) {
  final seasonId = season['id']?.toString() ?? '';
  final number = _int(season['season_number']);
  final episodes = season['episodes'];
  return MediaItem.tofa(
    id: TofaIds.season(show.id, seasonId),
    kind: MediaKind.season,
    title: _str(season['title']) ?? (number == 0 ? 'Specials' : 'Season ${number ?? ''}'.trim()),
    summary: _str(season['overview']),
    index: number,
    parentId: show.id,
    parentTitle: show.title,
    parentThumbPath: show.thumbPath,
    thumbPath: _str(season['poster_path']) ?? show.thumbPath,
    artPath: show.artPath,
    year: _yearOf(season['air_date']),
    leafCount: episodes is List ? episodes.length : _int(season['episode_count']),
    libraryId: show.libraryId,
    libraryTitle: show.libraryTitle,
    serverId: ctx.serverId,
    serverName: ctx.serverName,
    raw: {TofaRaw.nativeId: seasonId},
  );
}

/// An episode (`EpisodeWithFiles`) of [season] of [show]. [progress] is the
/// episode file's `WatchProgressResponse`, when known.
MediaItem mapEpisode(
  Map<String, dynamic> episode,
  MediaItem season,
  MediaItem show,
  TofaMappingContext ctx, {
  Map<String, dynamic>? progress,
}) {
  final episodeId = episode['id']?.toString() ?? '';
  final file = primaryFile(episode['files']);
  final completed = progress?['completed'] == true;
  final position = _int(progress?['position_ms']);
  final duration = _int(file?['duration_ms']) ?? ((_int(episode['runtime_minutes']) ?? 0) * 60000).nullIfZero;
  return MediaItem.tofa(
    id: TofaIds.episode(show.id, episodeId),
    kind: MediaKind.episode,
    title: _str(episode['title']),
    summary: _str(episode['overview']),
    index: _int(episode['episode_number']),
    parentIndex: season.index,
    parentId: season.id,
    parentTitle: season.title,
    parentThumbPath: season.thumbPath,
    grandparentId: show.id,
    grandparentTitle: show.title,
    grandparentThumbPath: show.thumbPath,
    grandparentArtPath: show.artPath,
    thumbPath: _str(episode['still_path']) ?? season.thumbPath,
    artPath: show.artPath,
    year: _yearOf(episode['air_date']),
    originallyAvailableAt: _str(episode['air_date']),
    contentRating: show.contentRating,
    durationMs: duration,
    viewCount: completed ? 1 : 0,
    viewOffsetMs: !completed && position != null && position > 0 ? position : null,
    lastViewedAt: _epochSeconds(progress?['last_watched_at']),
    mediaVersions: episode['files'] is List ? versionsOf(episode['files']) : null,
    libraryId: show.libraryId,
    libraryTitle: show.libraryTitle,
    serverId: ctx.serverId,
    serverName: ctx.serverName,
    raw: {TofaRaw.nativeId: episodeId, if (file != null) TofaRaw.fileId: file['id']?.toString()},
  );
}

/// A Continue Watching card (`ContinueWatchingItem`): a movie, or the
/// episode of a show to resume or start next.
MediaItem mapContinueItem(Map<String, dynamic> json, TofaMappingContext ctx) {
  final mediaId = json['media_id']?.toString() ?? '';
  final episodeId = _str(json['episode_id']);
  final position = _int(json['position_ms']);
  final duration = _int(json['duration_ms']);
  final updated = _epochSeconds(json['updated_at']);
  if (episodeId == null) {
    return MediaItem.tofa(
      id: mediaId,
      kind: MediaKind.movie,
      title: _str(json['title']),
      summary: _str(json['overview']),
      year: _int(json['year']),
      contentRating: _str(json['content_rating']),
      thumbPath: _str(json['poster_path']),
      artPath: _str(json['backdrop_path']),
      clearLogoPath: _str(json['logo_path']),
      durationMs: duration,
      viewOffsetMs: position != null && position > 0 ? position : null,
      lastViewedAt: updated,
      genres: _strings(json['genres']),
      serverId: ctx.serverId,
      serverName: ctx.serverName,
      raw: {TofaRaw.fileId: json['media_file_id']?.toString()},
    );
  }
  final seasonId = _str(json['season_id']) ?? '';
  return MediaItem.tofa(
    id: TofaIds.episode(mediaId, episodeId),
    kind: MediaKind.episode,
    title: _str(json['episode_title']),
    summary: _str(json['overview']),
    index: _int(json['episode_number']),
    parentIndex: _int(json['season_number']),
    parentId: TofaIds.season(mediaId, seasonId),
    grandparentId: mediaId,
    grandparentTitle: _str(json['title']),
    grandparentThumbPath: _str(json['poster_path']),
    grandparentArtPath: _str(json['backdrop_path']),
    thumbPath: _str(json['backdrop_thumb']) ?? _str(json['poster_path']),
    artPath: _str(json['backdrop_path']),
    clearLogoPath: _str(json['logo_path']),
    originallyAvailableAt: _str(json['air_date']),
    contentRating: _str(json['content_rating']),
    durationMs: duration,
    viewOffsetMs: position != null && position > 0 ? position : null,
    lastViewedAt: updated,
    serverId: ctx.serverId,
    serverName: ctx.serverName,
    raw: {TofaRaw.nativeId: episodeId, TofaRaw.fileId: json['media_file_id']?.toString(), 'kind': json['kind']},
  );
}

extension on int {
  int? get nullIfZero => this == 0 ? null : this;
}
