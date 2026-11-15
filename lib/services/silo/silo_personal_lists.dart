/// Silo's personal lists, paged through `GET /api/v2/catalog?source=…`
/// (Silo Android `FavoritesViewModel` / `WatchlistViewModel`): the only route
/// that pages them with a sort and a media-type filter.
enum SiloPersonalList {
  favorites('favorites'),
  watchlist('watchlist');

  const SiloPersonalList(this.source);

  /// The catalog `source` value.
  final String source;
}
