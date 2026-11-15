import '../../i18n/strings.g.dart';

/// Row titles the Silo server words itself (Home and library sections,
/// recommendation rows) carry `title_key` and, when the message has
/// placeholders, `title_args`: a key of Silo's shared translation catalog
/// (`home.section.*`) whose English is the row's `title`. A client that knows
/// the key shows its own translation; otherwise, and whenever the fields are
/// absent (an administrator or the profile typed the title), it shows `title`
/// (silo-server `docs/catalog-api.md`, "Section titles").
abstract final class SiloSectionTitles {
  static const _prefix = 'home.section.';

  /// The title to show for a row whose JSON is [row] (`title`, `title_key`,
  /// `title_args`).
  static String of(Map<String, dynamic> row) =>
      localize(titleKey: row['title_key'], titleArgs: row['title_args'], fallback: row['title']?.toString() ?? '');

  /// [titleKey] in the app's language with [titleArgs] filled in, or
  /// [fallback] when the key is unknown or a placeholder it needs is missing.
  static String localize({required Object? titleKey, Object? titleArgs, required String fallback}) {
    if (titleKey is! String || !titleKey.startsWith(_prefix)) return fallback;
    final args = <String, String>{
      if (titleArgs is Map)
        for (final MapEntry(:key, :value) in titleArgs.entries)
          if (value != null && value.toString().trim().isNotEmpty) key.toString(): value.toString(),
    };
    return _translate(titleKey.substring(_prefix.length), args) ?? fallback;
  }

  static String? _translate(String name, Map<String, String> args) {
    final s = t.siloSectionTitles;
    String? withArg(String arg, String Function(String value) build) {
      final value = args[arg];
      return value == null ? null : build(value);
    }

    return switch (name) {
      'forYou' => s.forYou,
      'recommendedForYou' => s.recommendedForYou,
      'becauseYouWatched' => s.becauseYouWatched,
      'becauseYouWatchedTitle' => withArg('title', (v) => s.becauseYouWatchedTitle(title: v)),
      'becauseYouEnjoy' => withArg('genres', (v) => s.becauseYouEnjoy(genres: v)),
      'pickedFromYourHistory' => s.pickedFromYourHistory,
      'profilesLikeYouEnjoyed' => s.profilesLikeYouEnjoyed,
      'popularOnServer' => s.popularOnServer,
      'trendingOnServer' => s.trendingOnServer,
      'trendingThisWeek' => s.trendingThisWeek,
      'topPicksToday' => s.topPicksToday,
      'topRated' => s.topRated,
      'topRatedMovies' => s.topRatedMovies,
      'topRatedTv' => s.topRatedTv,
      'topGenre' => withArg('genre', (v) => s.topGenre(genre: v)),
      'highlyRatedInLibrary' => s.highlyRatedInLibrary,
      'hiddenGems' => s.hiddenGems,
      'randomPicks' => s.randomPicks,
      'seasonalPicks' => s.seasonalPicks,
      'returningShows' => s.returningShows,
      'continueWatching' => s.continueWatching,
      'continueListening' => s.continueListening,
      'continueReading' => s.continueReading,
      'nextUp' => s.nextUp,
      'nextInYourSeries' => s.nextInYourSeries,
      'recentlyAdded' => s.recentlyAdded,
      'recentlyAddedIn' => withArg('library', (v) => s.recentlyAddedIn(library: v)),
      'recentlyAddedMovies' => s.recentlyAddedMovies,
      'recentlyAddedTv' => s.recentlyAddedTv,
      'recentlyAddedAudiobooks' => s.recentlyAddedAudiobooks,
      'recentlyAddedEbooks' => s.recentlyAddedEbooks,
      'recentlyAddedManga' => s.recentlyAddedManga,
      'recentlyReleased' => s.recentlyReleased,
      'recentlyReleasedIn' => withArg('library', (v) => s.recentlyReleasedIn(library: v)),
      'recentlyReleasedMovies' => s.recentlyReleasedMovies,
      'recentlyReleasedEpisodes' => s.recentlyReleasedEpisodes,
      'recentlyReleasedEpisodesIn' => withArg('library', (v) => s.recentlyReleasedEpisodesIn(library: v)),
      'recentlyReleasedAudiobooks' => s.recentlyReleasedAudiobooks,
      'recentlyReleasedEbooks' => s.recentlyReleasedEbooks,
      'recentlyReleasedManga' => s.recentlyReleasedManga,
      _ => null,
    };
  }
}
