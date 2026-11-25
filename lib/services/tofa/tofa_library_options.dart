import '../../i18n/strings.g.dart';
import '../../media/library_filter_result.dart';
import '../../media/library_genre.dart';
import '../../media/library_query.dart';
import '../../media/media_filter.dart';
import '../../media/media_sort.dart';

/// `GET /api/v1/media/facets`: the filter and sort values a library offers
/// ("the set of available filter and sort values for the media library, such
/// as genres, quality tokens, watch-status options, year range, and default
/// sort settings"). Plezilo offers only what this answer lists: `/media`'s
/// own `sort`, `order`, `watched` and `quality` parameters are free strings
/// in the spec.
class TofaFacets {
  const TofaFacets({
    required this.sorts,
    required this.defaultSort,
    required this.defaultOrder,
    required this.genres,
    required this.quality,
    required this.watched,
    required this.letters,
    this.yearMin,
    this.yearMax,
  });

  final List<String> sorts;
  final String defaultSort;
  final String defaultOrder;
  final List<String> genres;
  final List<String> quality;

  /// The watch-status options with a count (`WatchedFacets`: `watched`,
  /// `in_progress`, `unwatched`). Unverified: that these names are the
  /// values `/media?watched=` takes; the spec gives them only as the facet's
  /// field names, which is the only vocabulary it documents.
  final List<String> watched;
  final List<String> letters;
  final int? yearMin;
  final int? yearMax;

  static List<String> _values(Object? raw) => [
    if (raw is List)
      for (final option in raw.whereType<Map>())
        if (option['value'] is String && (option['value'] as String).isNotEmpty) option['value'] as String,
  ];

  static TofaFacets? fromJson(Object? data) {
    if (data is! Map) return null;
    final sorts = data['sorts'];
    final watched = data['watched'];
    final years = data['years'];
    return TofaFacets(
      sorts: [
        if (sorts is List)
          for (final s in sorts)
            if (s is String && s.isNotEmpty) s,
      ],
      defaultSort: data['default_sort'] is String ? data['default_sort'] as String : '',
      defaultOrder: data['default_order'] is String ? data['default_order'] as String : '',
      genres: _values(data['genres']),
      quality: _values(data['quality']),
      letters: _values(data['letters']),
      watched: [
        if (watched is Map)
          for (final key in const ['unwatched', 'in_progress', 'watched'])
            if (watched[key] is num) key,
      ],
      yearMin: years is Map && years['min'] is int ? years['min'] as int : null,
      yearMax: years is Map && years['max'] is int ? years['max'] as int : null,
    );
  }

  /// Whether `order` takes `asc` / `desc`: only when the server's own
  /// default order is spelled that way (the spec types `order` as a string).
  bool get ordersAscDesc => defaultOrder == 'asc' || defaultOrder == 'desc';
}

/// Filter fields of a Tofa library (the `filter` of each [MediaFilter]).
abstract final class TofaFilterField {
  static const genre = MediaFilterField.genre;
  static const year = MediaFilterField.year;
  static const quality = 'tofa:quality';
  static const watched = 'tofa:watched';
  static const availableOnly = 'tofa:available_only';
}

/// Sort values Tofa's facets may list that have a label in Plezilo. Any other
/// value the server lists is still offered, under its own name.
const Map<String, String Function()> _sortLabels = {
  'title': _title,
  'sort_title': _title,
  'added_at': _added,
  'created_at': _added,
  'date_added': _added,
  'release_date': _release,
  'year': _year,
  'rating': _rating,
  'imdb_rating': _imdb,
  'runtime': _runtime,
  'runtime_minutes': _runtime,
  'random': _random,
  'last_watched': _viewed,
  'last_watched_at': _viewed,
};

String _title() => t.libraries.sortLabels.title;
String _added() => t.libraries.sortLabels.dateAdded;
String _release() => t.libraries.sortLabels.releaseDate;
String _year() => t.libraries.sortLabels.year;
String _rating() => t.libraries.sortLabels.rating;
String _imdb() => t.libraries.sortLabels.imdbRating;
String _runtime() => t.libraries.sortLabels.runtime;
String _random() => t.libraries.sortLabels.random;
String _viewed() => t.libraries.sortLabels.dateViewed;

/// The sort values a server lists that mean "date added", newest first with
/// `order=desc`: the only way Plezilo builds a "Recently added" row. Checked
/// against what `/media/facets` lists, never sent unlisted.
const tofaDateAddedSorts = ['added_at', 'created_at', 'date_added'];

/// Sort and filter lists from [TofaFacets].
abstract final class TofaLibraryOptions {
  static String _humanize(String value) {
    final words = value.replaceAll(RegExp(r'[_\-.]+'), ' ').trim();
    if (words.isEmpty) return value;
    return words[0].toUpperCase() + words.substring(1);
  }

  /// One [MediaSort] per listed sort value. Descending variants exist only
  /// when `order` is known to take `asc` / `desc`.
  static List<MediaSort> sorts(TofaFacets facets) => [
    for (final value in facets.sorts)
      MediaSort(
        key: value,
        descKey: facets.ordersAscDesc && value != 'random' ? '$value:desc' : null,
        title: _sortLabels[value]?.call() ?? _humanize(value),
        defaultDirection: value == facets.defaultSort && facets.ordersAscDesc ? facets.defaultOrder : null,
      ),
  ];

  static String watchedLabel(String value) => switch (value) {
    'unwatched' => t.libraries.filterCategories.unwatched,
    'in_progress' => t.libraries.tofaInProgress,
    'watched' => t.libraries.tofaWatched,
    _ => _humanize(value),
  };

  static LibraryFilterResult filters(TofaFacets facets) {
    const valueOperators = [LibraryFilterOperator.is_];
    final filters = <MediaFilter>[];
    final cached = <String, List<MediaFilterValue>>{};
    void tag(String field, String title, List<String> values, String Function(String) label) {
      if (values.isEmpty) return;
      filters.add(
        MediaFilter(
          filter: field,
          filterType: MediaFilterType.tag,
          key: field,
          title: title,
          type: 'filter',
          operators: valueOperators,
        ),
      );
      cached[field] = [for (final v in values) MediaFilterValue(key: v, title: label(v))];
    }

    tag(TofaFilterField.genre, t.libraries.filterCategories.genre, facets.genres, (v) => v);
    tag(TofaFilterField.watched, t.libraries.tofaWatchStatus, facets.watched, watchedLabel);
    tag(TofaFilterField.quality, t.libraries.tofaQuality, facets.quality, (v) => v);
    if (facets.yearMin != null && facets.yearMax != null) {
      filters.add(
        MediaFilter(
          filter: TofaFilterField.year,
          filterType: MediaFilterType.integer,
          key: '',
          title: t.libraries.filterCategories.year,
          type: 'filter',
          operators: const [LibraryFilterOperator.is_, LibraryFilterOperator.atLeast, LibraryFilterOperator.atMost],
        ),
      );
    }
    filters.add(
      MediaFilter(
        filter: TofaFilterField.availableOnly,
        filterType: MediaFilterType.boolean,
        key: '',
        title: t.libraries.tofaAvailableOnly,
        type: 'filter',
        operators: valueOperators,
      ),
    );
    return LibraryFilterResult(filters: filters, cachedValues: cached);
  }

  static List<LibraryGenre> genres(List<String> names) => [
    for (final name in names) LibraryGenre(title: name, filterValue: name),
  ];

  /// `/media` query parameters for [query]'s sort and filters, given the
  /// [facets] that say which values exist. Unlisted values are dropped.
  static Map<String, String> queryParams(LibraryQuery query, TofaFacets? facets) {
    final out = <String, String>{};
    final sort = query.sort;
    if (sort != null && facets != null) {
      var field = sort.field;
      var descending = sort.direction == LibrarySortDirection.descending;
      if (field.endsWith(':desc')) {
        field = field.substring(0, field.length - 5);
        descending = true;
      } else if (field.endsWith(':asc')) {
        field = field.substring(0, field.length - 4);
        descending = false;
      }
      if (facets.sorts.contains(field)) {
        out['sort'] = field;
        if (facets.ordersAscDesc && field != 'random') out['order'] = descending ? 'desc' : 'asc';
      }
    }
    for (final filter in query.filters) {
      final values = filter.values.where((v) => v.isNotEmpty).toList();
      if (values.isEmpty || filter.op.isNegated) continue;
      switch (filter.field) {
        case TofaFilterField.genre:
          // `genres` (plural) takes several; its separator is not documented,
          // so one genre goes as `genre` and more are not combined.
          out['genre'] = values.first;
        case TofaFilterField.watched when facets?.watched.contains(values.first) ?? false:
          out['watched'] = values.first;
        case TofaFilterField.quality when facets?.quality.contains(values.first) ?? false:
          out['quality'] = values.first;
        case TofaFilterField.availableOnly when values.first == '1' || values.first == 'true':
          out['available_only'] = 'true';
        case TofaFilterField.year:
          final year = int.tryParse(values.first);
          if (year == null) break;
          switch (filter.op) {
            case LibraryFilterOperator.atLeast:
              out['year_from'] = '$year';
            case LibraryFilterOperator.atMost:
              out['year_to'] = '$year';
            default:
              out['year'] = '$year';
          }
      }
    }
    return out;
  }
}
