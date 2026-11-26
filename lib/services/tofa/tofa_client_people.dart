part of 'tofa_client.dart';

/// People and trailers.
///
/// - A cast member (`CastMember`) and a people-search hit (`ActorSuggestion`,
///   from `GET /search`'s `actors`) are named only; Plezilo's person id is
///   `tofa-person:<name>`. Their titles in the library are `GET /media` with
///   `cast=<name>` (unverified: the spec does not say whether `cast` takes a
///   name; it is the only person value `/media` and search hand out), and the
///   biography is `GET /discovery/people/by-name`.
/// - A title's trailer is its `youtube_trailer_id`, opened as a YouTube
///   trailer like other servers' remote trailers.
extension _TofaPeople on TofaClient {
  static const personPrefix = 'tofa-person:';

  static String? nameOf(String personId) => personId.startsWith(personPrefix) && personId.length > personPrefix.length
      ? personId.substring(personPrefix.length)
      : null;

  Future<List<MediaPerson>> _searchPeople(String query, int limit, AbortController? abort) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data = await _api.getJson(
      '/api/v1/search',
      query: {'q': q, 'actor_limit': '$limit', 'movie_limit': '0', 'discover_limit': '0'},
      abort: abort,
    );
    final rows = data is Map && data['actors'] is List ? data['actors'] as List : const [];
    return [
      for (final row in rows.whereType<Map<String, dynamic>>())
        // Every person listed must open a page with titles.
        if (row['name'] is String && (row['name'] as String).isNotEmpty && (flexibleInt(row['media_count']) ?? 0) > 0)
          MediaPerson(
            id: '$personPrefix${row['name']}',
            name: row['name'] as String,
            thumbPath: TofaMappers.art(row['profile_url']),
            backend: MediaBackend.tofa,
            serverId: serverId,
            serverName: serverName,
          ),
    ];
  }

  Future<LibraryPage<MediaItem>> _personMedia(String personId, int? start, int? size, AbortController? abort) async {
    final name = nameOf(personId);
    if (name == null) return const LibraryPage(items: [], totalCount: 0);
    return _mediaQuery({'cast': name}, offset: start ?? 0, limit: size ?? 50, abort: abort);
  }

  Future<MediaPersonDetails> _personDetails(String personId, AbortController? abort) async {
    final name = nameOf(personId);
    if (name == null) return MediaPersonDetails.empty;
    try {
      final data = await _api.getJson('/api/v1/discovery/people/by-name', query: {'name': name}, abort: abort);
      if (data is! Map) return MediaPersonDetails.empty;
      final bio = data['biography'];
      final place = data['place_of_birth'];
      return MediaPersonDetails(
        biography: bio is String && bio.trim().isNotEmpty ? bio.trim() : null,
        birthDate: MediaPersonDetails.parseDate(data['birthday']),
        deathDate: MediaPersonDetails.parseDate(data['deathday']),
        birthPlace: place is String && place.isNotEmpty ? place : null,
      );
    } on MediaServerHttpException catch (e) {
      if (e.isCancellation) rethrow;
      // Discovery off on the server, or no match: the page shows titles only.
      appLogger.d('[tofa] person details unavailable (HTTP ${e.statusCode})');
      return MediaPersonDetails.empty;
    }
  }

  Future<List<RemoteTrailer>> _remoteTrailers(String id) async {
    if (TofaMappers.parseCollectionId(id) != null) return const [];
    final mediaId = TofaMappers.mediaIdOf(id);
    // Episodes and seasons list their series' trailer only on the series.
    if (mediaId != id) return const [];
    final item = await _fetchItem(mediaId);
    final key = item?.raw?['youtube_trailer_id'];
    if (key is! String || key.trim().isEmpty) return const [];
    return [RemoteTrailer(site: 'YouTube', key: key.trim(), kind: 'trailer')];
  }
}
