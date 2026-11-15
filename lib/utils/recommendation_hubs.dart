import '../media/media_hub.dart';

/// [recommendations] (rows with [MediaHub.personalRecommendations]) without
/// the ones that are really a row Home already shows from the same server:
/// every card is in that row, or most of them are (four in five), or it has
/// the same title and at least half of its cards. A Home row that only
/// shares a title or a kind (Silo's "Recommended for You" section beside
/// its For You feed) but holds other cards does not hide a recommendation.
({List<MediaHub> kept, int dropped}) withoutRecommendationsShownOnHome(
  List<MediaHub> recommendations,
  List<MediaHub> homeHubs,
) {
  if (recommendations.isEmpty) return (kept: recommendations, dropped: 0);
  final homeRows = [
    for (final hub in homeHubs)
      if (!hub.personalRecommendations && hub.items.isNotEmpty)
        (serverId: hub.serverId, title: _normalizedTitle(hub.title), ids: {for (final item in hub.items) item.id}),
  ];
  final kept = <MediaHub>[];
  for (final row in recommendations) {
    final ids = {for (final item in row.items) item.id};
    final title = _normalizedTitle(row.title);
    final duplicate =
        ids.isNotEmpty &&
        homeRows.any((home) {
          if (home.serverId != row.serverId) return false;
          final shared = ids.where(home.ids.contains).length;
          if (shared == ids.length || shared * 5 >= ids.length * 4) return true;
          return title.isNotEmpty && title == home.title && shared * 2 >= ids.length;
        });
    if (!duplicate) kept.add(row);
  }
  return (kept: kept, dropped: recommendations.length - kept.length);
}

String _normalizedTitle(String title) => title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
