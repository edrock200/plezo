/// Item ids of an IPTV source. None holds a login or a stream address.
///
/// - `m<stream_id>`: an Xtream movie.
/// - `s<series_id>`: a series; `s<series_id>.<season>`: one of its seasons.
/// - `e<series_id>.<episode_id>`: an episode.
/// - `c<channel_id>`: a live channel.
/// - `r<recording_id>`: a local recording.
sealed class IptvItemId {
  const IptvItemId();

  static IptvItemId? parse(String id) {
    if (id.length < 2) return null;
    final body = id.substring(1);
    switch (id[0]) {
      case 'm':
        return IptvMovieId(body);
      case 's':
        final dot = body.lastIndexOf('.');
        if (dot > 0) {
          final season = int.tryParse(body.substring(dot + 1));
          if (season != null) return IptvSeasonId(body.substring(0, dot), season);
        }
        return IptvSeriesId(body);
      case 'e':
        final dot = body.indexOf('.');
        if (dot <= 0 || dot == body.length - 1) return null;
        return IptvEpisodeId(body.substring(0, dot), body.substring(dot + 1));
      case 'c':
        return IptvChannelItemId(body);
      case 'r':
        return IptvRecordingId(body);
    }
    return null;
  }
}

final class IptvMovieId extends IptvItemId {
  const IptvMovieId(this.streamId);
  final String streamId;
  @override
  String toString() => 'm$streamId';
}

final class IptvSeriesId extends IptvItemId {
  const IptvSeriesId(this.seriesId);
  final String seriesId;
  @override
  String toString() => 's$seriesId';
}

final class IptvSeasonId extends IptvItemId {
  const IptvSeasonId(this.seriesId, this.season);
  final String seriesId;
  final int season;
  @override
  String toString() => 's$seriesId.$season';
}

final class IptvEpisodeId extends IptvItemId {
  const IptvEpisodeId(this.seriesId, this.episodeId);
  final String seriesId;
  final String episodeId;
  @override
  String toString() => 'e$seriesId.$episodeId';
}

final class IptvChannelItemId extends IptvItemId {
  const IptvChannelItemId(this.channelId);
  final String channelId;
  @override
  String toString() => 'c$channelId';
}

final class IptvRecordingId extends IptvItemId {
  const IptvRecordingId(this.recordingId);
  final String recordingId;
  @override
  String toString() => 'r$recordingId';
}

/// Library ids of an Xtream source.
abstract final class IptvLibraryIds {
  static const movies = 'movies';
  static const series = 'series';
}
