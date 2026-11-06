import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import 'silo_api.dart';

/// Silo's media requests (`/api/v2/requests/...`): what a profile may
/// request, title search, a title's request detail, creating and cancelling a
/// request, and the account's own requests.
///
/// Ports the shared request model of Silo's Android apps
/// (`shared/.../model/request/RequestModels.kt`, `RequestDisplayState.kt`,
/// `RequestPresentation.kt`, `RequestMutations.kt`, `network/api/RequestsApi.kt`)
/// so every surface agrees on a request's state. Request administration
/// (approve, decline, retry) stays in Silo's web admin, as on Silo's own apps.

int? _int(Object? v) => v is int ? v : (v is num && v.isFinite ? v.toInt() : null);
double? _double(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
String _strOr(Object? v) => v is String ? v : '';
List<String> _strings(Object? v) => v is List ? [for (final e in v) ?_str(e)] : const [];
Map<String, dynamic> _map(Object? v) => v is Map<String, dynamic> ? v : const {};

/// Media types Plezilo shows from the request provider. Silo also lists
/// audiobooks and ebooks, which Plezilo cannot play.
bool siloRequestSupportedType(String? mediaType) => mediaType == 'movie' || mediaType == 'series';

/// `GET /api/v2/requests/status`. The contract requires `allowed` and
/// `state`; an answer without them counts as unavailable (fails closed).
@immutable
class SiloRequestsStatus {
  const SiloRequestsStatus({
    required this.requestsEnabled,
    this.allowed,
    this.state,
    this.followSupported = false,
    this.seasonRequestsSupported = false,
    this.removeFailedSupported = false,
  });

  factory SiloRequestsStatus.fromJson(Map<String, dynamic> json) => SiloRequestsStatus(
    requestsEnabled: json['requests_enabled'] == true,
    allowed: json['allowed'] is bool ? json['allowed'] as bool : null,
    state: _str(json['state']),
    followSupported: json['follow_supported'] == true,
    seasonRequestsSupported: json['season_requests_supported'] == true,
    removeFailedSupported: json['remove_failed_supported'] == true,
  );

  final bool requestsEnabled;
  final bool? allowed;
  final String? state;
  final bool followSupported;
  final bool seasonRequestsSupported;

  /// The server takes `DELETE /api/v2/requests/{id}` for the viewer's own
  /// failed request (Silo Android #792); absent (false) on older servers.
  final bool removeFailedSupported;

  /// The feature is on and this profile may use it (a blocked account sees
  /// `allowed: false`).
  bool get isAvailable => requestsEnabled && allowed == true && state == 'available';
}

/// A title's request annotation (`request` on search results and details).
@immutable
class SiloRequestState {
  const SiloRequestState({
    this.status,
    this.state,
    this.requestable = false,
    this.reason = '',
    this.requestId,
    this.following = false,
    this.requestedByViewer = false,
  });

  factory SiloRequestState.fromJson(Map<String, dynamic> json) => SiloRequestState(
    status: _str(json['status']),
    state: _str(json['state']),
    requestable: json['requestable'] == true,
    reason: _strOr(json['reason']),
    requestId: _str(json['request_id']?.toString()),
    following: json['following'] == true,
    requestedByViewer: json['requested_by_viewer'] == true,
  );

  final String? status;
  final String? state;
  final bool requestable;
  final String reason;
  final String? requestId;
  final bool following;
  final bool requestedByViewer;

  /// This state once the server deleted [record]: requestable again, unless
  /// it shows a different request (Silo's `RequestState.without`).
  SiloRequestState without(SiloMediaRequest record) =>
      requestId == record.id ? const SiloRequestState(requestable: true) : this;
}

/// One title from the request provider (`/requests/search`, recommendations).
@immutable
class SiloRequestMediaResult {
  const SiloRequestMediaResult({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.year,
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.releaseDate,
    this.voteAverage,
    this.availability = 'missing',
    this.libraryContentId,
    this.request = const SiloRequestState(),
  });

  static SiloRequestMediaResult? fromJson(Object? raw) {
    final json = _map(raw);
    final mediaType = _str(json['media_type']);
    final tmdbId = _int(json['tmdb_id']);
    final title = _str(json['title']);
    if (mediaType == null || tmdbId == null || title == null) return null;
    return SiloRequestMediaResult(
      mediaType: mediaType,
      tmdbId: tmdbId,
      title: title,
      year: _int(json['year']),
      overview: _strOr(json['overview']),
      posterPath: _str(json['poster_path']),
      backdropPath: _str(json['backdrop_path']),
      releaseDate: _str(json['release_date']),
      voteAverage: _double(json['vote_average']),
      availability: _str(json['availability']) ?? 'missing',
      libraryContentId: _str(json['library_content_id']),
      request: SiloRequestState.fromJson(_map(json['request'])),
    );
  }

  final String mediaType;
  final int tmdbId;
  final String title;
  final int? year;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? releaseDate;
  final double? voteAverage;
  final String availability;
  final String? libraryContentId;
  final SiloRequestState request;

  String get key => '$mediaType:$tmdbId';

  SiloRequestDisplay? get display => SiloRequestDisplay.ofAnnotation(availability, request);

  SiloRequestMediaResult withRequest(SiloRequestState request) => SiloRequestMediaResult(
    mediaType: mediaType,
    tmdbId: tmdbId,
    title: title,
    year: year,
    overview: overview,
    posterPath: posterPath,
    backdropPath: backdropPath,
    releaseDate: releaseDate,
    voteAverage: voteAverage,
    availability: availability,
    libraryContentId: libraryContentId,
    request: request,
  );
}

/// [results] once the server deleted [record]: its title is requestable again
/// (Silo's `applyingRemoval`). Returns [results] itself when nothing changed.
List<SiloRequestMediaResult> siloResultsApplyingRemoval(List<SiloRequestMediaResult> results, SiloMediaRequest record) {
  List<SiloRequestMediaResult>? patched;
  for (final (i, result) in results.indexed) {
    if (result.mediaType != record.mediaType || result.tmdbId != record.tmdbId) continue;
    final request = result.request.without(record);
    if (identical(request, result.request)) continue;
    (patched ??= List.of(results))[i] = result.withRequest(request);
  }
  return patched ?? results;
}

/// `GET /requests/detail/{media_type}/{tmdb_id}`.
@immutable
class SiloRequestMediaDetail {
  const SiloRequestMediaDetail({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.imdbId = '',
    this.tvdbId,
    this.tagline = '',
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.releaseDate,
    this.year,
    this.runtime,
    this.genres = const [],
    this.voteAverage,
    this.contentRating = '',
    this.numberOfSeasons,
    this.director = '',
    this.cast = const [],
    this.availability = 'missing',
    this.libraryContentId,
    this.request = const SiloRequestState(),
  });

  static SiloRequestMediaDetail? fromJson(Object? raw) {
    final json = _map(raw);
    final mediaType = _str(json['media_type']);
    final tmdbId = _int(json['tmdb_id']);
    final title = _str(json['title']);
    if (mediaType == null || tmdbId == null || title == null) return null;
    final cast = json['cast'] is List ? json['cast'] as List : const [];
    return SiloRequestMediaDetail(
      mediaType: mediaType,
      tmdbId: tmdbId,
      title: title,
      imdbId: _strOr(json['imdb_id']),
      tvdbId: _int(json['tvdb_id']),
      tagline: _strOr(json['tagline']),
      overview: _strOr(json['overview']),
      posterPath: _str(json['poster_path']),
      backdropPath: _str(json['backdrop_path']),
      releaseDate: _str(json['release_date']) ?? _str(json['first_air_date']),
      year: _int(json['year']),
      runtime: _int(json['runtime']),
      genres: _strings(json['genres']),
      voteAverage: _double(json['vote_average']),
      contentRating: _strOr(json['content_rating']),
      numberOfSeasons: _int(json['number_of_seasons']),
      director: _strOr(json['director']),
      cast: [for (final member in cast) ?_str(_map(member)['name'])],
      availability: _str(json['availability']) ?? 'missing',
      libraryContentId: _str(json['library_content_id']),
      request: SiloRequestState.fromJson(_map(json['request'])),
    );
  }

  final String mediaType;
  final int tmdbId;
  final String title;
  final String imdbId;
  final int? tvdbId;
  final String tagline;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? releaseDate;
  final int? year;
  final int? runtime;
  final List<String> genres;
  final double? voteAverage;
  final String contentRating;
  final int? numberOfSeasons;
  final String director;
  final List<String> cast;
  final String availability;
  final String? libraryContentId;
  final SiloRequestState request;

  SiloRequestDisplay? get display => SiloRequestDisplay.ofAnnotation(availability, request);

  /// `POST /api/v2/requests`. A series request names no seasons: the server
  /// then requests every aired season the library does not have complete.
  Map<String, dynamic> toCreateBody() => {
    'media_type': mediaType,
    'tmdb_id': tmdbId,
    'tvdb_id': ?tvdbId,
    if (imdbId.isNotEmpty) 'imdb_id': imdbId,
    'title': title,
    'year': ?year,
    if (overview.isNotEmpty) 'overview': overview,
    'poster_path': ?posterPath,
    'backdrop_path': ?backdropPath,
  };

  /// The detail as the server's answer to the viewer's own create or cancel
  /// leaves it (Silo's `MediaRequest.toRequestState`).
  SiloRequestMediaDetail withRecord(SiloMediaRequest record) =>
      _withRequest(record.toRequestState(), libraryContentId ?? record.libraryContentId);

  /// The detail once the server deleted [record]: requestable again.
  SiloRequestMediaDetail withoutRecord(SiloMediaRequest record) =>
      _withRequest(request.without(record), libraryContentId);

  SiloRequestMediaDetail _withRequest(SiloRequestState request, String? libraryContentId) => SiloRequestMediaDetail(
    mediaType: mediaType,
    tmdbId: tmdbId,
    title: title,
    imdbId: imdbId,
    tvdbId: tvdbId,
    tagline: tagline,
    overview: overview,
    posterPath: posterPath,
    backdropPath: backdropPath,
    releaseDate: releaseDate,
    year: year,
    runtime: runtime,
    genres: genres,
    voteAverage: voteAverage,
    contentRating: contentRating,
    numberOfSeasons: numberOfSeasons,
    director: director,
    cast: cast,
    availability: availability,
    libraryContentId: libraryContentId,
    request: request,
  );
}

/// One download target of a request (1080p, 4K, ...).
@immutable
class SiloRequestTarget {
  const SiloRequestTarget({required this.quality, required this.status});
  final String quality;
  final String status;
}

/// One of the account's own requests (`/requests/mine`, create, cancel).
@immutable
class SiloMediaRequest {
  const SiloMediaRequest({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.status,
    required this.outcome,
    this.state,
    this.year,
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.libraryContentId,
    this.outcomeReason = '',
    this.lastError = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.targets = const [],
  });

  static SiloMediaRequest? fromJson(Object? raw) {
    final json = _map(raw);
    final id = _str(json['id']?.toString());
    final mediaType = _str(json['media_type']);
    final tmdbId = _int(json['tmdb_id']);
    if (id == null || mediaType == null || tmdbId == null) return null;
    final targets = json['targets'] is List ? json['targets'] as List : const [];
    return SiloMediaRequest(
      id: id,
      mediaType: mediaType,
      tmdbId: tmdbId,
      title: _strOr(json['title']),
      status: _strOr(json['status']),
      outcome: _strOr(json['outcome']),
      state: _str(json['state']),
      year: _int(json['year']),
      overview: _strOr(json['overview']),
      posterPath: _str(json['poster_path']),
      backdropPath: _str(json['backdrop_path']),
      libraryContentId: _str(json['library_content_id']),
      outcomeReason: _strOr(json['outcome_reason']),
      lastError: _strOr(json['last_error']),
      createdAt: _strOr(json['created_at']),
      updatedAt: _strOr(json['updated_at']),
      targets: [
        for (final target in targets)
          SiloRequestTarget(quality: _strOr(_map(target)['quality']), status: _strOr(_map(target)['status'])),
      ],
    );
  }

  final String id;
  final String mediaType;
  final int tmdbId;
  final String title;
  final String status;
  final String outcome;
  final String? state;
  final int? year;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? libraryContentId;
  final String outcomeReason;
  final String lastError;
  final String createdAt;
  final String updatedAt;
  final List<SiloRequestTarget> targets;

  bool get isActive => outcome == 'active';

  SiloRequestDisplay get display => SiloRequestDisplay.ofRecord(this);

  /// Only a pending request can still be withdrawn by its requester.
  bool get canCancel => isActive && display.kind == SiloRequestDisplayKind.pending;

  /// The server's rule for removing a request (Silo's `isRemovableFailure`,
  /// #792): it failed and delivered nothing. One that delivered a quality
  /// before failing stays as the record of that copy.
  bool get isRemovableFailure => outcome == 'failed' && !targets.any((target) => target.status == 'completed');

  /// The compact annotation a record implies (Silo's `toRequestState`):
  /// active requests block re-requesting, closed ones re-open it.
  SiloRequestState toRequestState() => switch (outcome) {
    'cancelled' => const SiloRequestState(requestable: true),
    'declined' || 'failed' => SiloRequestState(status: status, state: state, requestable: true, requestId: id),
    _ => SiloRequestState(status: status, state: state, requestId: id, requestedByViewer: true),
  };
}

/// What a request looks like to its user (Silo's `RequestDisplayState`).
enum SiloRequestDisplayKind { pending, onTheWay, inLibrary, attention, unavailable }

/// Why a request needs attention.
enum SiloRequestAttention { declined, failed }

@immutable
class SiloRequestDisplay {
  const SiloRequestDisplay(this.kind, {this.attention, this.reason = ''});

  final SiloRequestDisplayKind kind;
  final SiloRequestAttention? attention;

  /// A reason code (`quota_exceeded`) or the server's own sentence.
  final String reason;

  /// From a full request record.
  static SiloRequestDisplay ofRecord(SiloMediaRequest record) {
    final state = record.state ?? '';
    final closed =
        state == 'declined' ||
        state == 'cancelled' ||
        (state.isEmpty && (record.outcome == 'declined' || record.outcome == 'cancelled'));
    final reason = !closed && record.lastError.isNotEmpty ? record.lastError : record.outcomeReason;
    return _fromUserState(state, reason) ?? _fromStatus(record.status, record.outcome, reason);
  }

  /// From a search/detail annotation; null when the title can be requested
  /// and nobody has.
  static SiloRequestDisplay? ofAnnotation(String availability, SiloRequestState request) {
    final fromState = _fromUserState(request.state ?? '', '');
    if (fromState != null) return fromState;
    if (availability == 'available') return const SiloRequestDisplay(SiloRequestDisplayKind.inLibrary);
    final status = request.status;
    if (status != null && status.isNotEmpty) return _fromStatus(status, 'active', '');
    if (request.requestable) return null;
    return SiloRequestDisplay(SiloRequestDisplayKind.unavailable, reason: request.reason);
  }

  static SiloRequestDisplay? _fromUserState(String state, String reason) => switch (state) {
    'pending' => const SiloRequestDisplay(SiloRequestDisplayKind.pending),
    'approved' || 'processing' || 'partially_available' => const SiloRequestDisplay(SiloRequestDisplayKind.onTheWay),
    'available' => const SiloRequestDisplay(SiloRequestDisplayKind.inLibrary),
    'declined' => SiloRequestDisplay(
      SiloRequestDisplayKind.attention,
      attention: SiloRequestAttention.declined,
      reason: reason,
    ),
    'failed' => SiloRequestDisplay(
      SiloRequestDisplayKind.attention,
      attention: SiloRequestAttention.failed,
      reason: reason,
    ),
    'cancelled' => SiloRequestDisplay(SiloRequestDisplayKind.unavailable, reason: reason),
    _ => null,
  };

  static SiloRequestDisplay _fromStatus(String status, String outcome, String reason) {
    if (outcome == 'declined') {
      return SiloRequestDisplay(
        SiloRequestDisplayKind.attention,
        attention: SiloRequestAttention.declined,
        reason: reason,
      );
    }
    if (outcome == 'failed' || status == 'failed') {
      return SiloRequestDisplay(
        SiloRequestDisplayKind.attention,
        attention: SiloRequestAttention.failed,
        reason: reason,
      );
    }
    if (outcome == 'cancelled') return SiloRequestDisplay(SiloRequestDisplayKind.unavailable, reason: reason);
    if (status == 'pending') return const SiloRequestDisplay(SiloRequestDisplayKind.pending);
    if (status == 'completed') return const SiloRequestDisplay(SiloRequestDisplayKind.inLibrary);
    return const SiloRequestDisplay(SiloRequestDisplayKind.onTheWay);
  }

  /// The catalog item to open instead of the request: only "In library"
  /// with a known item (Silo's `libraryItemToOpen`). Everything else opens
  /// the request detail so its state and reason stay visible.
  String? libraryItemToOpen(String? libraryContentId) =>
      kind == SiloRequestDisplayKind.inLibrary && libraryContentId != null && libraryContentId.isNotEmpty
      ? libraryContentId
      : null;

  @override
  bool operator ==(Object other) =>
      other is SiloRequestDisplay && other.kind == kind && other.attention == attention && other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, attention, reason);

  @override
  String toString() => 'SiloRequestDisplay($kind, $attention, $reason)';
}

/// A library search's "Available to request" row offers only titles the
/// library does not have: the library results above it show the rest (Silo
/// Android #773, `withoutLibraryTitles`).
List<SiloRequestMediaResult> siloRequestsWithoutLibraryTitles(Iterable<SiloRequestMediaResult> results) => [
  for (final result in results)
    if (result.availability != 'available') result,
];

/// My Requests order (Silo's `MyRequestsBucket`): in motion, needs attention,
/// in the library; newest first in each. Cancelled requests drop off, as do
/// media types Plezilo cannot show.
List<SiloMediaRequest> siloBucketMyRequests(Iterable<SiloMediaRequest> records) {
  final inMotion = <SiloMediaRequest>[];
  final attention = <SiloMediaRequest>[];
  final landed = <SiloMediaRequest>[];
  for (final record in records) {
    if (!siloRequestSupportedType(record.mediaType)) continue;
    switch (record.display.kind) {
      case SiloRequestDisplayKind.pending || SiloRequestDisplayKind.onTheWay:
        inMotion.add(record);
      case SiloRequestDisplayKind.attention:
        attention.add(record);
      case SiloRequestDisplayKind.inLibrary:
        landed.add(record);
      case SiloRequestDisplayKind.unavailable:
        break;
    }
  }
  int newestFirst(SiloMediaRequest a, SiloMediaRequest b) =>
      _instantKey(b.createdAt).compareTo(_instantKey(a.createdAt));
  return [...inMotion..sort(newestFirst), ...attention..sort(newestFirst), ...landed..sort(newestFirst)];
}

/// The newest active request for a title, else the newest unless it was
/// cancelled.
SiloMediaRequest? siloCurrentRequestFor(Iterable<SiloMediaRequest> records, String mediaType, int tmdbId) {
  final mine = [
    for (final record in records)
      if (record.mediaType == mediaType && record.tmdbId == tmdbId) record,
  ]..sort((a, b) => _instantKey(b.createdAt).compareTo(_instantKey(a.createdAt)));
  for (final record in mine) {
    if (record.isActive) return record;
  }
  if (mine.isEmpty || mine.first.outcome == 'cancelled') return null;
  return mine.first;
}

/// An RFC 3339 instant as a sortable key: the fraction padded to 9 digits.
String _instantKey(String value) {
  final match = RegExp(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$').firstMatch(value);
  if (match == null) return value;
  return '${match.group(1)}.${(match.group(2) ?? '').padRight(9, '0')}Z';
}

/// TMDB artwork: request titles carry TMDB image paths, which Silo's apps
/// load from TMDB's CDN (`requestPosterUrl` / `requestBackdropUrl`).
String? siloRequestImageUrl(String? path, {bool backdrop = false}) {
  if (path == null || path.trim().isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  if (path.startsWith('/')) return 'https://image.tmdb.org/t/p/${backdrop ? 'w780' : 'w500'}$path';
  return path;
}

/// Why a create, cancel or removal failed.
enum SiloRequestFailureKind {
  /// The call may have reached the server but no usable answer came back:
  /// never resend it; a fresh read shows what happened.
  uncertain,

  /// The server turned requests off (`capability_*`): re-read the status.
  disabled,

  /// `validation_failed`.
  invalid,

  /// Anything else the server answered; [SiloRequestFailure.detail] is its copy.
  refused,
}

class SiloRequestFailure implements Exception {
  const SiloRequestFailure(this.kind, {this.detail, this.statusCode});

  final SiloRequestFailureKind kind;
  final String? detail;
  final int? statusCode;

  /// Sorts a failed mutation (Silo's `RequestMutationFailure` and
  /// `RequestActionCopy`). Both are non-retryable on the server: a resend
  /// after an uncertain outcome could act twice.
  static SiloRequestFailure classify(Object error) {
    if (error is SiloRequestFailure) return error;
    if (error is MediaServerHttpException) {
      final status = error.statusCode;
      final code = siloProblemCode(error.responseData);
      if (status == null) return const SiloRequestFailure(SiloRequestFailureKind.uncertain);
      if (const {502, 503, 504}.contains(status) && code == null) {
        return SiloRequestFailure(SiloRequestFailureKind.uncertain, statusCode: status);
      }
      if (code == 'validation_failed') return SiloRequestFailure(SiloRequestFailureKind.invalid, statusCode: status);
      if (code != null && code.startsWith('capability_')) {
        return SiloRequestFailure(SiloRequestFailureKind.disabled, statusCode: status);
      }
      return SiloRequestFailure(
        SiloRequestFailureKind.refused,
        detail: siloProblemDetail(error.responseData),
        statusCode: status,
      );
    }
    // An answer this client could not read: the server acted.
    return const SiloRequestFailure(SiloRequestFailureKind.uncertain);
  }

  @override
  String toString() => 'SiloRequestFailure($kind, $statusCode)';
}

/// The request calls of one Silo client (one account acting as one profile),
/// and the feature gate its entry points read.
class SiloRequestsApi {
  SiloRequestsApi(this._api, {this.isOffline});

  final SiloApi _api;
  final bool Function()? isOffline;

  /// Whether this profile may use requests: false until a status read says
  /// so; a failed read keeps the previous answer, so a blip does not yank a
  /// visible entry point (Silo's `RequestsFeatureStore`).
  final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// The server lets the viewer remove their own failed requests
  /// (`remove_failed_supported`); false while requests are off. Kept through a
  /// failed read like [enabled].
  final ValueNotifier<bool> removeFailedSupported = ValueNotifier(false);

  final StreamController<SiloMediaRequest> _removals = StreamController.broadcast();

  /// Each of the viewer's requests this client removed (or found already
  /// removed), so every request surface can drop it and make its title
  /// requestable again.
  Stream<SiloMediaRequest> get removals => _removals.stream;

  /// Whether [record] may offer Remove: a failed request that delivered
  /// nothing, on a server that takes removals.
  bool canRemove(SiloMediaRequest record) => removeFailedSupported.value && record.isRemovableFailure;

  /// A status read has answered (or failed) at least once.
  bool get resolved => _resolvedAt != null;
  DateTime? _resolvedAt;
  Future<bool>? _statusInFlight;

  static const statusFreshness = Duration(seconds: 30);

  /// Read `GET /requests/status` (one read in flight; skipped while the last
  /// answer is younger than [statusFreshness] unless [force]).
  Future<bool> refreshStatus({bool force = false}) {
    if (isOffline?.call() ?? false) return Future.value(enabled.value);
    final at = _resolvedAt;
    if (!force && at != null && DateTime.now().difference(at) < statusFreshness) return Future.value(enabled.value);
    return _statusInFlight ??= () async {
      try {
        final data = await _api.getJson('/api/v2/requests/status', timeout: const Duration(seconds: 8));
        final status = SiloRequestsStatus.fromJson(data);
        enabled.value = status.isAvailable;
        removeFailedSupported.value = status.isAvailable && status.removeFailedSupported;
      } catch (e) {
        appLogger.d('Silo requests: status unavailable; keeping enabled=${enabled.value}', error: e.runtimeType);
      } finally {
        _resolvedAt = DateTime.now();
        _statusInFlight = null;
      }
      return enabled.value;
    }();
  }

  /// `GET /requests/search?q=&media_type=&page=`; unsupported media types are
  /// dropped.
  Future<List<SiloRequestMediaResult>> search(String query, {String mediaType = 'all', int page = 1}) async {
    final data = await _api.getJson(
      '/api/v2/requests/search',
      query: {'q': query, 'media_type': mediaType, 'page': page},
    );
    final results = data['results'] is List ? data['results'] as List : const [];
    return [
      for (final raw in results)
        if (SiloRequestMediaResult.fromJson(raw) case final result? when siloRequestSupportedType(result.mediaType))
          result,
    ];
  }

  /// `GET /requests/detail/{media_type}/{tmdb_id}`.
  Future<SiloRequestMediaDetail> detail(String mediaType, int tmdbId) async {
    final data = await _api.getJson('/api/v2/requests/detail/${Uri.encodeComponent(mediaType)}/$tmdbId');
    final detail = SiloRequestMediaDetail.fromJson(data);
    if (detail == null) throw const FormatException('Request detail without identity');
    return detail;
  }

  /// `POST /api/v2/requests`. Sent once; failures come as [SiloRequestFailure].
  Future<SiloMediaRequest> create(SiloRequestMediaDetail detail) =>
      _mutate('POST', '/api/v2/requests', detail.toCreateBody());

  /// `POST /requests/{id}/cancel`.
  Future<SiloMediaRequest> cancel(String id) =>
      _mutate('POST', '/api/v2/requests/${Uri.encodeComponent(id)}/cancel', const <String, dynamic>{});

  /// `DELETE /api/v2/requests/{id}`: deletes one of the viewer's failed
  /// requests that delivered nothing (Silo Android #792). Answers 204, or 409
  /// once the request was retried, completed or delivered a copy. A 404 means
  /// another device removed it already, so it counts as removed. Sent once,
  /// like [create] and [cancel]; failures come as [SiloRequestFailure]. A
  /// removal (204 or 404) is announced on [removals].
  Future<void> removeFailed(SiloMediaRequest record) async {
    try {
      await _send('DELETE', '/api/v2/requests/${Uri.encodeComponent(record.id)}', null);
    } on SiloRequestFailure catch (failure) {
      if (failure.kind != SiloRequestFailureKind.refused || failure.statusCode != 404) rethrow;
    }
    if (!_removals.isClosed) _removals.add(record);
  }

  Future<SiloMediaRequest> _mutate(String method, String path, Map<String, dynamic> body) async {
    final response = await _send(method, path, body);
    final record = SiloMediaRequest.fromJson(response.data);
    if (record == null) throw const SiloRequestFailure(SiloRequestFailureKind.uncertain);
    return record;
  }

  /// One mutation, never resent; a non-2xx answer or a transport failure
  /// becomes a [SiloRequestFailure].
  Future<MediaServerResponse> _send(String method, String path, Map<String, dynamic>? body) async {
    final MediaServerResponse response;
    try {
      response = await _api.request(method, path, body: body);
    } catch (e) {
      throw SiloRequestFailure.classify(e);
    }
    if (response.statusCode >= 400) {
      throw SiloRequestFailure.classify(
        MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          statusCode: response.statusCode,
          responseData: response.data,
          requestUri: response.requestUri,
        ),
      );
    }
    return response;
  }

  /// `GET /requests/mine`, following `page.next_cursor` (50 a page). A failed
  /// page, a missing or repeated cursor, or more than [maxPages] pages fails
  /// the whole load instead of returning a partial list.
  Future<List<SiloMediaRequest>> mine({int maxPages = 100}) async {
    final records = <SiloMediaRequest>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < maxPages; page++) {
      final data = await _api.getJson('/api/v2/requests/mine', query: {'limit': 50, 'cursor': ?cursor});
      final items = data['items'] is List ? data['items'] as List : const [];
      records.addAll([for (final raw in items) ?SiloMediaRequest.fromJson(raw)]);
      final info = _map(data['page']);
      if (info['has_more'] != true) return records;
      final next = _str(info['next_cursor']);
      if (next == null || !seen.add(next)) {
        throw const FormatException('The server returned invalid request pagination.');
      }
      cursor = next;
    }
    throw const FormatException('The request list exceeded the page limit.');
  }

  void dispose() {
    enabled.dispose();
    removeFailedSupported.dispose();
    unawaited(_removals.close());
  }
}
