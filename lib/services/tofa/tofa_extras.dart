/// Tofa's Discover, requests, watch history and profile models
/// (`/discovery/*`, `/requests*`, `/users/me/seen|not-interested`,
/// `/watch/history`, `/profiles`), read by `TofaClientExtras`.
library;

import '../../utils/json_utils.dart';

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

/// A title on a Discover shelf, the radar, a person page or a discovery
/// detail (`AnnotatedDiscoveryItem`, `RadarEntry`, `PersonPageCredit`,
/// `DetailResponse`): it may or may not be in the library.
class TofaDiscoverItem {
  const TofaDiscoverItem({
    required this.tmdbId,
    required this.type,
    required this.title,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.inLibrary = false,
    this.localMediaId,
    this.requestStatus,
    this.seen = false,
    this.notInterested = false,
    this.availableOn,
    this.roles = const [],
  });

  final int tmdbId;

  /// `movie` or `tv` (`DiscoveryItem.type`; `show`/`series` read as `tv`).
  final String type;
  final String title;
  final int? year;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final bool inLibrary;
  final String? localMediaId;
  final String? requestStatus;
  final bool seen;
  final bool notInterested;

  /// A radar entry's `available_on`.
  final String? availableOn;

  /// A person page credit's `roles`.
  final List<String> roles;

  bool get isShow => type == 'tv';

  static String _type(Object? v) => v == 'tv' || v == 'show' || v == 'series' ? 'tv' : 'movie';

  static TofaDiscoverItem? fromJson(Object? data) {
    if (data is! Map) return null;
    final tmdb = flexibleInt(data['tmdb_id']);
    final title = _str(data['title']);
    if (tmdb == null || title == null) return null;
    final release = _str(data['release_date']);
    return TofaDiscoverItem(
      tmdbId: tmdb,
      type: _type(data['type'] ?? data['media_type']),
      title: title,
      year:
          flexibleInt(data['year']) ??
          (release != null && release.length >= 4 ? int.tryParse(release.substring(0, 4)) : null),
      overview: _str(data['overview']),
      posterPath: _str(data['poster_path']),
      backdropPath: _str(data['backdrop_path']),
      inLibrary: data['in_library'] == true,
      localMediaId: _str(data['local_media_id']),
      requestStatus: _str(data['request_status']),
      seen: data['seen'] == true,
      notInterested: data['not_interested'] == true,
      availableOn: _str(data['available_on']),
      roles: [
        if (data['roles'] is List)
          for (final r in data['roles'] as List)
            if (r is String && r.isNotEmpty) r,
      ],
    );
  }

  TofaDiscoverItem copyWith({bool? seen, bool? notInterested, String? requestStatus}) => TofaDiscoverItem(
    tmdbId: tmdbId,
    type: type,
    title: title,
    year: year,
    overview: overview,
    posterPath: posterPath,
    backdropPath: backdropPath,
    inLibrary: inLibrary,
    localMediaId: localMediaId,
    requestStatus: requestStatus ?? this.requestStatus,
    seen: seen ?? this.seen,
    notInterested: notInterested ?? this.notInterested,
    availableOn: availableOn,
    roles: roles,
  );

  static List<TofaDiscoverItem> listOf(Object? rows) => [
    if (rows is List)
      for (final row in rows) ?fromJson(row),
  ];
}

/// One Discover shelf (`DiscoveryShelf`): a titled row, paged by
/// `next_cursor` through `GET /discovery/shelf/{key}`.
class TofaDiscoverShelf {
  const TofaDiscoverShelf({
    required this.key,
    required this.title,
    required this.items,
    this.subtitle,
    this.nextCursor,
    this.total,
  });

  final String key;
  final String title;
  final String? subtitle;
  final List<TofaDiscoverItem> items;
  final String? nextCursor;
  final int? total;

  bool get hasMore => nextCursor != null || (total != null && total! > items.length);

  static TofaDiscoverShelf? fromJson(Object? data) {
    if (data is! Map) return null;
    final key = _str(data['key']);
    final title = _str(data['title']);
    if (key == null || title == null) return null;
    return TofaDiscoverShelf(
      key: key,
      title: title,
      subtitle: _str(data['subtitle']),
      items: TofaDiscoverItem.listOf(data['items']),
      nextCursor: _str(data['next_cursor']),
      total: flexibleInt(data['total']),
    );
  }
}

/// A Discover lane (`DiscoveryLane`): a theme with shelves of its own.
class TofaDiscoverLane {
  const TofaDiscoverLane({required this.slug, required this.title, this.description, this.followed = false});

  final String slug;
  final String title;
  final String? description;
  final bool followed;

  static TofaDiscoverLane? fromJson(Object? data) {
    if (data is! Map) return null;
    final slug = _str(data['slug']);
    final title = _str(data['title']);
    if (slug == null || title == null) return null;
    return TofaDiscoverLane(
      slug: slug,
      title: title,
      description: _str(data['description']),
      followed: data['followed'] == true,
    );
  }
}

/// `GET /discovery/page`: heroes, shelves and lanes.
class TofaDiscoverPage {
  const TofaDiscoverPage({this.heroes = const [], this.shelves = const [], this.lanes = const []});

  final List<TofaDiscoverItem> heroes;
  final List<TofaDiscoverShelf> shelves;
  final List<TofaDiscoverLane> lanes;

  static TofaDiscoverPage fromJson(Object? data) {
    if (data is! Map) return const TofaDiscoverPage();
    return TofaDiscoverPage(
      heroes: [
        if (data['heroes'] is List)
          for (final h in data['heroes'] as List)
            if (h is Map) ?TofaDiscoverItem.fromJson(h['item']),
      ],
      shelves: [
        if (data['shelves'] is List)
          for (final s in data['shelves'] as List) ?TofaDiscoverShelf.fromJson(s),
      ],
      lanes: [
        if (data['lanes'] is List)
          for (final l in data['lanes'] as List) ?TofaDiscoverLane.fromJson(l),
      ],
    );
  }
}

/// A radar bucket (`RadarBucket`): titles arriving soon.
class TofaRadarBucket {
  const TofaRadarBucket({required this.title, required this.items, this.subtitle});

  final String title;
  final String? subtitle;
  final List<TofaDiscoverItem> items;

  static List<TofaRadarBucket> listOf(Object? data) => [
    if (data is Map && data['buckets'] is List)
      for (final b in (data['buckets'] as List).whereType<Map>())
        if (_str(b['title']) != null)
          TofaRadarBucket(
            title: _str(b['title'])!,
            subtitle: _str(b['subtitle']),
            items: TofaDiscoverItem.listOf(b['items']),
          ),
  ];
}

/// One of the viewer's request rights (`RequestAccess`).
enum TofaRequestAccess {
  off,

  /// The request waits for an admin.
  ask,

  /// The request is approved at once.
  auto;

  static TofaRequestAccess parse(Object? v) => switch (v) {
    'ask' => ask,
    'auto' => auto,
    _ => off,
  };
}

/// `GET /requests/rights` (`RequestRightsResponse`).
class TofaRequestRights {
  const TofaRequestRights({
    this.requestsAvailable = false,
    this.movie = TofaRequestAccess.off,
    this.tv = TofaRequestAccess.off,
    this.movie4k = TofaRequestAccess.off,
    this.tv4k = TofaRequestAccess.off,
    this.movieRemaining,
    this.tvRemaining,
  });

  final bool requestsAvailable;
  final TofaRequestAccess movie;
  final TofaRequestAccess tv;
  final TofaRequestAccess movie4k;
  final TofaRequestAccess tv4k;

  /// Requests left in the quota window (`QuotaStatus.remaining`); null with
  /// no quota.
  final int? movieRemaining;
  final int? tvRemaining;

  TofaRequestAccess accessFor(String type, {bool is4k = false}) =>
      type == 'tv' ? (is4k ? tv4k : tv) : (is4k ? movie4k : movie);

  bool get canRequestAnything => requestsAvailable && (movie != TofaRequestAccess.off || tv != TofaRequestAccess.off);

  static TofaRequestRights fromJson(Object? data) {
    if (data is! Map) return const TofaRequestRights();
    final rights = data['rights'] is Map ? data['rights'] as Map : const {};
    final quota = data['quota'] is Map ? data['quota'] as Map : const {};
    int? remaining(Object? q) => q is Map ? flexibleInt(q['remaining']) : null;
    return TofaRequestRights(
      requestsAvailable: data['requests_available'] == true,
      movie: TofaRequestAccess.parse(rights['movie']),
      tv: TofaRequestAccess.parse(rights['tv']),
      movie4k: TofaRequestAccess.parse(rights['movie_4k']),
      tv4k: TofaRequestAccess.parse(rights['tv_4k']),
      movieRemaining: remaining(quota['movie']),
      tvRemaining: remaining(quota['tv']),
    );
  }
}

/// One request (`EnrichedRequest`).
class TofaRequest {
  const TofaRequest({
    required this.id,
    required this.title,
    required this.type,
    required this.tmdbId,
    required this.status,
    this.is4k = false,
    this.createdAt,
    this.denialReason,
    this.downloadProgress,
  });

  final String id;
  final String title;
  final String type;
  final int tmdbId;

  /// `RequestStatus`: `pending_approval`, `requested`, `downloading`,
  /// `available`, `denied`, `failed`, `retrying`.
  final String status;
  final bool is4k;
  final DateTime? createdAt;
  final String? denialReason;

  /// `download.progress` (0-1 or 0-100; unverified, shown as a share of 1
  /// when ≤ 1).
  final double? downloadProgress;

  static TofaRequest? fromJson(Object? data) {
    if (data is! Map) return null;
    final id = _str(data['id']);
    final title = _str(data['title']);
    final tmdb = flexibleInt(data['tmdb_id']);
    final status = _str(data['status']);
    if (id == null || title == null || tmdb == null || status == null) return null;
    final download = data['download'];
    return TofaRequest(
      id: id,
      title: title,
      type: TofaDiscoverItem._type(data['media_type']),
      tmdbId: tmdb,
      status: status,
      is4k: data['is4k'] == true,
      createdAt: _str(data['created_at']) == null ? null : DateTime.tryParse(data['created_at'] as String),
      denialReason: _str(data['denial_reason']),
      downloadProgress: download is Map ? flexibleDouble(download['progress']) : null,
    );
  }
}

/// `GET /discovery/detail/{type}/{tmdb}` (`DetailResponse`): library and
/// request state for one title. Its descriptive fields are not in the
/// spec's schema (`additionalProperties`); read when present (unverified).
class TofaDiscoverDetail {
  const TofaDiscoverDetail({
    required this.item,
    this.requestsAvailable = false,
    this.requestBlocked = false,
    this.requestStatus,
    this.is4kCapable = false,
    this.rights,
    this.youtubeTrailerId,
    this.cast = const [],
  });

  final TofaDiscoverItem item;
  final bool requestsAvailable;
  final bool requestBlocked;
  final String? requestStatus;
  final bool is4kCapable;
  final TofaRequestRights? rights;
  final String? youtubeTrailerId;

  /// `(person_id, name, role)` of a `cast` list, when the answer has one.
  final List<({int personId, String name, String? role})> cast;

  static TofaDiscoverDetail fromJson(Object? data, TofaDiscoverItem fallback) {
    if (data is! Map) return TofaDiscoverDetail(item: fallback);
    final parsed = TofaDiscoverItem.fromJson({
      'tmdb_id': fallback.tmdbId,
      'title': fallback.title,
      ...data,
      'type': fallback.type,
    });
    final base = parsed ?? fallback;
    final rights = data['request_rights'];
    return TofaDiscoverDetail(
      item: TofaDiscoverItem(
        tmdbId: base.tmdbId,
        type: fallback.type,
        title: base.title,
        year: base.year ?? fallback.year,
        overview: base.overview ?? fallback.overview,
        posterPath: base.posterPath ?? fallback.posterPath,
        backdropPath: base.backdropPath ?? fallback.backdropPath,
        inLibrary: data['in_library'] == true,
        localMediaId: _str(data['local_media_id']),
        requestStatus: _str(data['request_status']),
        seen: data['seen'] == true,
        notInterested: data['not_interested'] == true,
      ),
      requestsAvailable: data['requests_available'] == true,
      requestBlocked: data['request_blocked'] == true,
      requestStatus: _str(data['request_status']),
      is4kCapable: data['is4k_capable'] == true,
      rights: rights is Map
          ? TofaRequestRights.fromJson({'requests_available': data['requests_available'], 'rights': rights})
          : null,
      youtubeTrailerId: _str(data['youtube_trailer_id']),
      cast: [
        if (data['cast'] is List)
          for (final c in (data['cast'] as List).whereType<Map>())
            if (flexibleInt(c['person_id']) != null && _str(c['name']) != null)
              (personId: flexibleInt(c['person_id'])!, name: _str(c['name'])!, role: _str(c['role'])),
      ],
    );
  }
}

/// `GET /discovery/people/{id}` (`PersonPage`).
class TofaPersonPage {
  const TofaPersonPage({required this.name, this.biography, this.profileUrl, this.credits = const []});

  final String name;
  final String? biography;
  final String? profileUrl;
  final List<TofaDiscoverItem> credits;

  static TofaPersonPage fromJson(Object? data, String fallbackName) {
    if (data is! Map) return TofaPersonPage(name: fallbackName);
    return TofaPersonPage(
      name: _str(data['name']) ?? fallbackName,
      biography: _str(data['biography']),
      profileUrl: _str(data['profile_url']),
      credits: TofaDiscoverItem.listOf(data['credits']),
    );
  }
}

/// One play in the profile's history (`PlaySessionListItem`).
class TofaHistoryEntry {
  const TofaHistoryEntry({
    required this.id,
    required this.title,
    required this.startedAt,
    this.mediaId,
    this.episodeTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.progressPercent,
    this.episodeId,
  });

  final String id;
  final String title;
  final DateTime? startedAt;
  final String? mediaId;
  final String? episodeId;
  final String? episodeTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? progressPercent;

  static TofaHistoryEntry? fromJson(Object? data) {
    if (data is! Map) return null;
    final id = _str(data['id']);
    final title = _str(data['title']);
    if (id == null || title == null) return null;
    return TofaHistoryEntry(
      id: id,
      title: title,
      startedAt: _str(data['started_at']) == null ? null : DateTime.tryParse(data['started_at'] as String),
      mediaId: _str(data['media_id']),
      episodeId: _str(data['episode_id']),
      episodeTitle: _str(data['episode_title']),
      seasonNumber: flexibleInt(data['season_number']),
      episodeNumber: flexibleInt(data['episode_number']),
      progressPercent: flexibleInt(data['progress_percent']),
    );
  }
}

/// A history page (`HistoryListResponse`).
class TofaHistoryPage {
  const TofaHistoryPage({required this.items, required this.hasMore});

  final List<TofaHistoryEntry> items;
  final bool hasMore;
}
