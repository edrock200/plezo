import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../media/media_sort.dart';

/// The media a Silo sort list is for (Silo's `CatalogSortScope`): a field
/// applies to a scope when the server can order that media by it.
enum SiloSortScope {
  movie,
  series,
  episode,
  audiobook;

  static const video = {movie, series, episode};
  static const media = {movie, series, episode, audiobook};
}

/// One catalog sort field, in the order and with the default direction of
/// Silo's web client (`web/src/lib/querySortOptions.ts`, mirrored by Silo
/// Android #843's `CatalogSortField`).
///
/// [key] is the [MediaSort.key] Plezilo stores for a library; the fields
/// Plezilo offered before keep their old keys so a saved sort still matches.
/// [wire] is the server's `sort` field.
class SiloSortField {
  const SiloSortField(
    this.key,
    this.wire, {
    required this.descending,
    required this.scopes,
    required this.label,
    this.ratingSource,
  });

  final String key;
  final String wire;
  final bool descending;
  final Set<SiloSortScope> scopes;
  final String Function() label;

  /// Listed only while the server shows this rating source
  /// (`GET /api/v2/capabilities/ratings`).
  final String? ratingSource;

  MediaSort toMediaSort() =>
      MediaSort(key: key, descKey: '$key:desc', title: label(), defaultDirection: descending ? 'desc' : 'asc');
}

/// Silo's library sort lists.
abstract final class SiloSortOptions {
  static final List<SiloSortField> fields = [
    SiloSortField(
      'title',
      'title',
      descending: false,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.title,
    ),
    SiloSortField(
      'addedAt',
      'added_at',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.dateAdded,
    ),
    SiloSortField(
      'releaseDate',
      'release_date',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.releaseDate,
    ),
    SiloSortField(
      'lastAirDate',
      'last_air_date',
      descending: true,
      scopes: {SiloSortScope.series, SiloSortScope.episode},
      label: () => t.libraries.sortLabels.latestEpisodeAirDate,
    ),
    SiloSortField(
      'latestEpisodeAdded',
      'latest_episode_added',
      descending: true,
      scopes: {SiloSortScope.series},
      label: () => t.libraries.sortLabels.latestEpisodeAdded,
    ),
    SiloSortField(
      'year',
      'year',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.year,
    ),
    SiloSortField(
      'contentRating',
      'content_rating',
      descending: false,
      scopes: SiloSortScope.video,
      label: () => t.libraries.sortLabels.contentRating,
    ),
    SiloSortField(
      'runtime',
      'runtime',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.duration,
    ),
    // `rating` was Plezilo's single rating sort; Silo reads it as IMDb.
    SiloSortField(
      'rating',
      'rating_imdb',
      descending: true,
      scopes: SiloSortScope.video,
      label: () => t.libraries.sortLabels.imdbRating,
    ),
    SiloSortField(
      'ratingTmdb',
      'rating_tmdb',
      descending: true,
      scopes: SiloSortScope.video,
      label: () => t.libraries.sortLabels.tmdbRating,
    ),
    SiloSortField(
      'ratingRtCritic',
      'rating_rt_critic',
      descending: true,
      scopes: SiloSortScope.video,
      label: () => t.libraries.sortLabels.rtCriticRating,
      ratingSource: 'rt_critic',
    ),
    SiloSortField(
      'ratingRtAudience',
      'rating_rt_audience',
      descending: true,
      scopes: SiloSortScope.video,
      label: () => t.libraries.sortLabels.rtAudienceRating,
      ratingSource: 'rt_audience',
    ),
    SiloSortField(
      'resolution',
      'resolution',
      descending: true,
      scopes: SiloSortScope.video,
      label: () => t.libraries.sortLabels.resolution,
    ),
    SiloSortField(
      'bitrate',
      'bitrate',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.bitrate,
    ),
    SiloSortField(
      'progress',
      'progress',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.progress,
    ),
    SiloSortField(
      'dateViewed',
      'date_viewed',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.dateViewed,
    ),
    SiloSortField(
      'plays',
      'plays',
      descending: true,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.plays,
    ),
    SiloSortField(
      'author',
      'author',
      descending: false,
      scopes: {SiloSortScope.audiobook},
      label: () => t.libraries.sortLabels.author,
    ),
    SiloSortField(
      'narrator',
      'narrator',
      descending: false,
      scopes: {SiloSortScope.audiobook},
      label: () => t.libraries.sortLabels.narrator,
    ),
    SiloSortField(
      'series',
      'series',
      descending: false,
      scopes: {SiloSortScope.audiobook},
      label: () => t.libraries.sortLabels.series,
    ),
    // Not in the web client's list, but Silo sorts by it and Plezilo has
    // always offered it.
    SiloSortField(
      'random',
      'random',
      descending: false,
      scopes: SiloSortScope.media,
      label: () => t.libraries.sortLabels.random,
    ),
  ];

  static final Map<String, SiloSortField> _byKey = {for (final field in fields) field.key: field};

  /// Neutral sort keys other screens may send, on top of each field's own.
  static const _aliases = {
    'titleSort': 'title',
    'productionYear': 'year',
    'originallyAvailableAt': 'releaseDate',
    'duration': 'runtime',
  };

  /// The field a stored or neutral sort key names, or null for one Silo
  /// does not sort by.
  static SiloSortField? byKey(String key) => _byKey[_aliases[key] ?? key];

  /// The scope a library of [libraryType] (a [MediaKind] id) is sorted in;
  /// null for a mixed library, which lists only fields that order movies,
  /// series and episodes alike.
  static SiloSortScope? scopeFor(String? libraryType) => switch (MediaKind.fromString(libraryType)) {
    MediaKind.movie => SiloSortScope.movie,
    MediaKind.show => SiloSortScope.series,
    MediaKind.episode => SiloSortScope.episode,
    MediaKind.album => SiloSortScope.audiobook,
    _ => null,
  };

  /// The fields one library's sort list offers, in display order.
  /// A rating sort is left out while the server does not show its source.
  static List<SiloSortField> forScope(SiloSortScope? scope, {required Set<String> shownRatingSources}) => [
    for (final field in fields)
      if ((scope == null ? field.scopes.containsAll(SiloSortScope.video) : field.scopes.contains(scope)) &&
          (field.ratingSource == null || shownRatingSources.contains(field.ratingSource)))
        field,
  ];
}
