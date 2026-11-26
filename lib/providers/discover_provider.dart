import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media/home_watch_state.dart';
import '../media/ids.dart';
import '../media/media_hub.dart';
import '../media/library_change_event.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../mixins/event_aware.dart';
import '../services/settings_service.dart';
import '../services/silo/silo_memberships.dart';
import '../services/data_aggregation_service.dart';
import '../services/system_shelf_service.dart';
import '../utils/app_logger.dart';
import '../utils/coalesced_load_coordinator.dart';
import '../utils/deletion_notifier.dart';
import '../utils/media_event_keys.dart';
import '../utils/global_key_utils.dart';
import '../utils/media_hub_ordering.dart';
import '../utils/recommendation_hubs.dart';
import '../utils/watch_state_notifier.dart';
import '../utils/library_content_notifier.dart';
import '../utils/refresh_pacer.dart';
import 'hidden_libraries_provider.dart';
import 'libraries_provider.dart';
import 'multi_server_provider.dart';
import 'watch_state_store.dart';

enum DiscoverLoadState { initial, loading, loaded, error }

/// What asked [DiscoverProvider.refreshHomeWatchState] to re-read the rows of
/// servers whose Home can be read alone (Silo).
enum HomeWatchStateTrigger {
  /// Home was shown again: a tab switch back to it, or a return from a pushed
  /// route (a detail page, the player).
  shown,

  /// The app came back to the foreground with Home on screen.
  resumed,

  /// The server's event stream said the profile's watch state changed (or a
  /// reconnect / the periodic check stood in for it).
  event,

  /// A read that left rows out for a transient reason, read again.
  retry,
}

enum DiscoverRefreshOutcome {
  /// Both surfaces completed without a failed or cancelled server leg.
  refreshed,

  /// Some content refreshed, but at least one server leg failed or was cancelled.
  degraded,

  /// At least one server leg failed and none succeeded.
  failed,

  /// The pass was interrupted or had no attempted server legs.
  cancelled,
}

DiscoverRefreshOutcome _refreshOutcome({
  required Set<String> succeededServerIds,
  required Set<String> failedServerIds,
  required Set<String> cancelledServerIds,
  required bool cancelled,
}) {
  if (cancelled) return DiscoverRefreshOutcome.cancelled;
  if (failedServerIds.isNotEmpty) {
    return succeededServerIds.isEmpty ? DiscoverRefreshOutcome.failed : DiscoverRefreshOutcome.degraded;
  }
  if (cancelledServerIds.isNotEmpty) {
    return succeededServerIds.isEmpty ? DiscoverRefreshOutcome.cancelled : DiscoverRefreshOutcome.degraded;
  }
  return succeededServerIds.isEmpty ? DiscoverRefreshOutcome.cancelled : DiscoverRefreshOutcome.refreshed;
}

/// Owns the Discover tab's data: the Continue Watching row and the home hub
/// list, including the refresh policy that used to live in the screen —
/// durable watch events refresh only Continue Watching (one on-deck call,
/// zero hub refetches), playback progress patches the visible row in place,
/// deletions drop the item from every visible list in place and then refresh
/// only Continue Watching, hidden-library changes trigger a full reload,
/// library-order changes re-sort hubs in place without refetching, the
/// platform launcher shelf syncs from every on-deck update, a tab-shown or
/// app-resume older than [staleAfter] runs a full pass, and a server push
/// event ([LibraryContentNotifier]) runs a debounced full pass so new
/// server-side media surfaces while the app is open (#1646).
///
/// Lives inside the profile-keyed provider subtree, so a profile switch
/// resets it by construction. The screen is a consumer: it renders this
/// state and keeps only UI concerns (hero carousel, focus, spotlight).
class DiscoverProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  /// Preview row caps at 20; one extra item is fetched as a probe so
  /// [hasMoreContinueWatching] can show the "more" affordance without a
  /// second request.
  static const int continueWatchingPreviewLimit = 20;
  static const int _continueWatchingProbeLimit = continueWatchingPreviewLimit + 1;

  /// Home hubs refetch when the tab is shown or the app resumes after this
  /// long. New media added server-side is otherwise invisible until a restart,
  /// because nothing pushes library changes to the client (#1646).
  static const Duration staleAfter = Duration(minutes: 15);

  DiscoverProvider(
    this._multiServer,
    this._hiddenLibraries,
    this._libraries, {
    required this.profileId,
    required this.isProfileBinding,
    WatchStateStore? watchStateStore,
    DateTime Function()? now,
    bool Function()? isRefreshBlocked,
    this.libraryEventDebounce = const Duration(seconds: 3),
    this.libraryEventBlockedRetry = const Duration(seconds: 15),
    this.libraryEventCooldown = const Duration(minutes: 2),
    this.watchStateShownThrottle = const Duration(seconds: 10),
    this.watchStateEventDebounce = const Duration(seconds: 2),
    this.watchStateRetryBase = const Duration(seconds: 1),
    Future<void> Function(String profileId, List<MediaItem>)? syncSystemShelf,
    Future<void> Function(String profileId, List<MediaServerClient> clients)? syncServerSources,
    // A private field cannot be a named initializing formal callers can pass.
    // ignore: prefer_initializing_formals
  }) : _watchStateStore = watchStateStore,
       _now = now ?? DateTime.now,
       _isRefreshBlocked = isRefreshBlocked ?? _neverBlocked,
       _syncSystemShelfOverride = syncSystemShelf,
       _syncServerSourcesOverride = syncServerSources {
    _loadCoordinator = CoalescedLoadCoordinator<String>(onFull: _loadOnce, onDelta: _loadDeltaOnce);
    _libraryEventPacer = RefreshPacer(
      debounce: libraryEventDebounce,
      cooldown: libraryEventCooldown,
      blockedRetry: libraryEventBlockedRetry,
      isBlocked: _isRefreshBlocked,
      runPass: _runLibraryEventRefresh,
    );
    // Late server connects (reconnect after outage, slow wave) refresh
    // discover the same way they refresh libraries. Removed in [dispose] so a
    // profile switch can't leave a stale listener on the app-global provider.
    _multiServer.addOnlineServersListener(_onOnlineServersChanged);
    _watchRecommendationsSetting();
    _hiddenLibraries.addListener(_onHiddenLibrariesChanged);
    _lastSeenLibraryOrderKeys = _libraryOrderKeys();
    _libraries.addListener(_onLibrariesChanged);
    _watchStateSubscription = subscribeToHierarchicalEvents<WatchStateEvent>(
      notifier: WatchStateNotifier(),
      mounted: () => !isDisposed,
      serverId: () => null,
      globalKeys: () => _watchedGlobalKeys,
      itemIds: () => _watchedIds,
      onEvent: _onWatchStateChanged,
    );
    _deletionSubscription = subscribeToHierarchicalEvents<DeletionEvent>(
      notifier: DeletionNotifier(),
      mounted: () => !isDisposed,
      serverId: () => null,
      globalKeys: () => _deletionGlobalKeys,
      itemIds: () => _deletionIds,
      onEvent: _onDeletion,
    );
    _libraryEventSubscription = LibraryContentNotifier().stream.listen(_onLibraryContentChanged);
    _shelfPublicationSubscription = SystemShelfService().publicationResumed.listen(_onShelfPublicationResumed);
    _siloMembershipSubscription = SiloMembershipStore.changes.listen(_onSiloMembershipChanged);
  }

  StreamSubscription<SiloMembershipChange>? _siloMembershipSubscription;

  /// A title went on or off a Silo Watchlist or Favorites list: a Home row
  /// that shows that list (`section_type` watchlist / favorites) is read
  /// again so the title appears or goes.
  void _onSiloMembershipChanged(SiloMembershipChange change) {
    if (isDisposed) return;
    final shown = _hubs.any((hub) => hub.serverId == change.serverId && hub.identifier == change.kind.sectionType);
    if (shown) unawaited(load());
  }

  final MultiServerProvider _multiServer;
  final HiddenLibrariesProvider _hiddenLibraries;
  final LibrariesProvider _libraries;

  /// Injectable clock for the [staleAfter] check; tests advance it instead of
  /// sleeping — same seam as `ContentRefreshResumeGate`.
  final DateTime Function() _now;

  /// Server push arrived (#1646): defers while [_isRefreshBlocked] (active
  /// video playback — the playback path must stay quiet) and merges bursts
  /// from several servers into one coalesced full pass.
  final bool Function() _isRefreshBlocked;

  /// Debounce for merging push bursts; blocked-retry interval while playback
  /// holds the refresh; cooldown bounding pass frequency while a server keeps
  /// emitting (a bulk import batches `LibraryChanged` every ~30 s for its
  /// whole duration — without the cooldown that is a full fan-out per batch).
  /// All injectable so tests drive them with short real waits. A committed
  /// pull pass credits the cooldown through [RefreshPacer.notePass], so a
  /// push landing just after a stale-resume refresh defers instead of
  /// fanning out an identical load.
  final Duration libraryEventDebounce;
  final Duration libraryEventBlockedRetry;
  final Duration libraryEventCooldown;

  static bool _neverBlocked() => false;
  StreamSubscription<LibraryChangeEvent>? _libraryEventSubscription;
  StreamSubscription<String>? _shelfPublicationSubscription;
  late final RefreshPacer _libraryEventPacer;

  /// Authoritative fetches tell the store which items the server re-observed,
  /// so a stale local watch patch stops overriding fresh server state (#1829).
  /// Optional: tests and isolated subtrees may have no store.
  final WatchStateStore? _watchStateStore;
  final String? profileId;

  /// Watermark plus store identity captured before an authoritative request.
  /// Null when there is no store to reconcile against.
  ({int watermark, Object epoch})? _beginObservation() {
    final store = _watchStateStore;
    if (store == null) return null;
    return (watermark: store.observationWatermark, epoch: store.observationEpoch);
  }

  /// Tell the store which items a *successful and committed* pass re-observed,
  /// so their stale local watch patches stop overriding the fresh server rows.
  ///
  /// Only ever called once the same disposed / generation / exception checks
  /// that authorise committing those rows have passed. Recording earlier would
  /// suppress a patch whose fresh row was then discarded or rolled back,
  /// leaving an older snapshot on screen with nothing to correct it. A
  /// zero-success pass observed nothing and records nothing.
  void _recordObservations(
    ({int watermark, Object epoch})? observation,
    List<({MediaItem item, String? clientScope})> rows,
    Set<String> succeededServerIds,
  ) {
    final store = _watchStateStore;
    if (store == null || observation == null || succeededServerIds.isEmpty || rows.isEmpty) return;
    store.recordObservations(
      [
        for (final row in rows)
          if (succeededServerIds.contains(row.item.serverId)) row,
      ],
      watermark: observation.watermark,
      epoch: observation.epoch,
    );
  }

  /// Whether the profile binder is still wiring servers. No full pass or
  /// Continue Watching refresh fetches while it runs: a profile switch mounts
  /// the new session before the binder rotates the shared Plex clients to the
  /// new user's token, so a fetch here would return the previous user's rows
  /// (#2599). main_screen primes a load once binding settles. A bind that
  /// starts mid-pass keeps a zero-success pass in the loading state instead
  /// of flashing the empty placeholder.
  final bool Function() isProfileBinding;
  final Future<void> Function(String profileId, List<MediaItem>)? _syncSystemShelfOverride;
  final Future<void> Function(String profileId, List<MediaServerClient> clients)? _syncServerSourcesOverride;

  StreamSubscription<WatchStateEvent>? _watchStateSubscription;
  StreamSubscription<DeletionEvent>? _deletionSubscription;

  List<MediaItem> _onDeck = [];

  /// [ContinueWatchingRows.copies] for the rows the last on-deck fetch
  /// returned, widened by [loadAllContinueWatching]. Lookups go through
  /// [continueWatchingCopiesOf]; a key with no row on screen is harmless.
  Map<String, List<MediaItem>> _continueWatchingCopies = const {};

  List<MediaHub> _hubs = [];
  bool _hasMoreContinueWatching = false;
  DiscoverLoadState _onDeckState = DiscoverLoadState.initial;
  DiscoverLoadState _hubsState = DiscoverLoadState.initial;
  String? _errorMessage;
  int _loadGeneration = 0;
  int _contentRevision = 0;
  int _commitRevision = 0;
  DiscoverRefreshOutcome _lastOutcome = DiscoverRefreshOutcome.cancelled;
  Future<void>? _continueWatchingRefreshFuture;
  bool _continueWatchingRefreshQueued = false;

  Set<String> _lastSeenHiddenKeys = {};
  List<String> _lastSeenLibraryOrderKeys = const [];

  /// Online servers whose Continue Watching legs succeeded without a failure
  /// or cancellation in the current on-deck list. Tracked separately from hubs
  /// so a transient failure in one surface does not cache the other as loaded
  /// forever or force unnecessary refetches.
  Set<String> _loadedOnDeckServerIds = {};

  /// Online servers whose home-hub legs all succeeded in the current hub list.
  Set<String> _loadedHubServerIds = {};

  /// When the last full pass committed a fresh hub list. Left untouched by
  /// kept-previous-hubs failures, rollbacks, and delta merges, so a pass that
  /// did not actually replace the hubs stays stale and is retried.
  DateTime? _hubsLoadedAt;

  Set<String> get _fullyLoadedServerIds => _loadedOnDeckServerIds.intersection(_loadedHubServerIds);

  /// Personal recommendation rows ([PersonalRecommendationsClient]) load
  /// beside each pass and are added to [hubs] when they arrive, after the
  /// pass's own rows: Home never waits for them. Each read gets the next
  /// number; a server's rows are replaced only by a read started after the
  /// one that produced them, so a slow read landing late never undoes a
  /// newer one.
  int _recommendationsGeneration = 0;
  final Map<String, int> _recommendationsAppliedGeneration = {};
  final Set<Future<void>> _recommendationsInFlight = {};

  /// Completes when every recommendation read started so far has been applied
  /// (or dropped).
  @visibleForTesting
  Future<void> get recommendationsSettled => Future.wait(_recommendationsInFlight.toList());

  late final CoalescedLoadCoordinator<String> _loadCoordinator;

  Future<void>? _systemShelfSyncFuture;
  List<MediaItem>? _pendingSystemShelfItems;

  List<MediaItem> get onDeck => _onDeck;

  /// Every copy merged into the Continue Watching row [item] — the same title
  /// in another library or on another server — best-first, with [item]
  /// standing in for its own entry. Empty when the row stands alone.
  List<MediaItem> continueWatchingCopiesOf(MediaItem item) {
    final copies = _continueWatchingCopies[item.globalKey];
    if (copies == null) return const [];
    return [for (final copy in copies) copy.globalKey == item.globalKey ? item : copy];
  }

  /// The rows Home shows: without the personal recommendation rows while
  /// "Show Silo recommendations on Home" is off. The filtered list is kept
  /// until [_hubs] or the setting changes, so screens that cache on list
  /// identity keep their caches.
  List<MediaHub> get hubs {
    if (_recommendationsOnHome) return _hubs;
    if (!identical(_hubsWithoutRecommendationsSource, _hubs)) {
      _hubsWithoutRecommendationsSource = _hubs;
      _hubsWithoutRecommendations = [
        for (final hub in _hubs)
          if (!hub.personalRecommendations) hub,
      ];
    }
    return _hubsWithoutRecommendations;
  }

  List<MediaHub>? _hubsWithoutRecommendationsSource;
  List<MediaHub> _hubsWithoutRecommendations = const [];

  /// "Show Silo recommendations on Home" (on when settings are not loaded).
  static bool get _recommendationsOnHome =>
      SettingsService.instanceOrNull?.read(SettingsService.showSiloRecommendationsOnHome) ?? true;

  ValueListenable<bool>? _recommendationsSetting;

  void _watchRecommendationsSetting() {
    if (_recommendationsSetting != null) return;
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return;
    _recommendationsSetting = settings.listenable(SettingsService.showSiloRecommendationsOnHome)
      ..addListener(_onRecommendationsSettingChanged);
  }

  /// Off: Home drops the rows on its next build. On: read them now, so they
  /// come back without waiting for the next refresh.
  void _onRecommendationsSettingChanged() {
    if (isDisposed) return;
    if (_recommendationsOnHome && _hubsState == DiscoverLoadState.loaded && _multiServer.hasConnectedServers) {
      _startRecommendations(
        _multiServer.aggregationService.getRecommendationHubsFromAllServers(
          hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
        ),
        after: Future<void>.value(),
      );
    }
    safeNotifyListeners();
  }

  bool get hasMoreContinueWatching => _hasMoreContinueWatching;

  /// Raw load failure (unlocalized); the screen wraps it for display.
  String? get errorMessage => _errorMessage;

  /// True until the first on-deck result (or error) of a [load] pass lands.
  bool get isLoading => _onDeckState == DiscoverLoadState.initial || _onDeckState == DiscoverLoadState.loading;

  bool get areHubsLoading => _hubsState == DiscoverLoadState.initial || _hubsState == DiscoverLoadState.loading;

  /// Bumped when a full pass lands *first* content — the initial load, or a
  /// recovery from an empty/error state. The screen resets the hero carousel
  /// and takes initial focus only on a bump; every other committed pass
  /// (background full pass, delta merge, Continue Watching refresh) swaps the
  /// data in place and the hero clamps instead of resetting, so a server push
  /// or stale-resume refetch never yanks the viewer's position (#1646).
  int get loadGeneration => _loadGeneration;

  /// Refresh when a server comes online *mid-session* (reconnect, late wave) —
  /// its hubs and continue-watching rows are otherwise missing until a manual
  /// refresh. During profile binding this is a no-op: servers bind in waves
  /// and main_screen primes one [load] when binding settles, so reacting to
  /// each wave would multiply the (expensive) hub fan-out at startup.
  ///
  /// Once a full pass has loaded, only the genuinely new servers are fetched
  /// and merged in; already-loaded servers are not refetched.
  Future<void> syncToOnlineServers(Set<String> onlineServerIds) {
    if (isDisposed || onlineServerIds.isEmpty || isProfileBinding()) return Future<void>.value();
    if (_onDeckState == DiscoverLoadState.loaded &&
        _hubsState == DiscoverLoadState.loaded &&
        _fullyLoadedServerIds.containsAll(onlineServerIds)) {
      return Future<void>.value();
    }
    // Nothing (or a failed pass) to merge into yet — run the full load.
    if (_onDeckState != DiscoverLoadState.loaded || _hubsState != DiscoverLoadState.loaded) return load();
    return _loadCoordinator.requestDelta(onlineServerIds.difference(_fullyLoadedServerIds));
  }

  /// Full load of Continue Watching + hubs. Concurrent calls coalesce into
  /// the in-flight pass plus at most one trailing pass (so a request that
  /// arrives mid-load still observes its own fresh fetch). A pass requested
  /// while the profile binder runs ends without fetching or touching state.
  Future<void> load() {
    if (isDisposed) return Future<void>.value();
    return _loadCoordinator.requestFull();
  }

  Future<DiscoverRefreshOutcome> refreshNow() async {
    if (isDisposed) return DiscoverRefreshOutcome.cancelled;
    await _loadCoordinator.requestFull();
    if (isDisposed) return DiscoverRefreshOutcome.cancelled;
    return _lastOutcome;
  }

  /// Whether a [load] pass is already running. The startup online-entry hook
  /// uses this to skip a prime that would only duplicate the load the screen
  /// started in `initState`.
  bool get isLoadInFlight => _loadCoordinator.isBusy;

  /// Starts a full reload when the committed hub list is older than
  /// [staleAfter]. Returns true while a full pass is running, queued, or was
  /// started here, so callers can skip a Continue Watching-only refresh the
  /// full pass already covers. A busy *delta* pass (online-server merge) does
  /// not count: it never refetches already-loaded servers' hubs, so stale
  /// hubs still queue the full pass behind it. A never-committed hub list is
  /// not stale: initial load, error retry, and reconnect are owned by
  /// `initState`, `primeRefresh`, and the online-servers listener.
  bool refreshIfStale() {
    if (isDisposed) return false;
    if (_loadCoordinator.isFullActive) return true;
    final loadedAt = _hubsLoadedAt;
    if (loadedAt == null || _now().difference(loadedAt) <= staleAfter) return false;
    unawaited(load());
    return true;
  }

  /// A server pushed a library-content change (#1646). Pacing lives in
  /// [_libraryEventPacer]: bursts — several servers scanning at once, or a
  /// channel re-emitting — collapse into one debounced full pass; an active
  /// video playback defers the pass entirely (retried on a timer) so the
  /// playback path stays quiet; and passes run at most once per
  /// [libraryEventCooldown] so a long import updates the home screen
  /// periodically instead of continuously. The first event after a quiet
  /// period always refreshes promptly.
  void _onLibraryContentChanged(LibraryChangeEvent event) {
    if (isDisposed || !event.hasChanges) return;
    _libraryEventPacer.schedule();
  }

  bool _runLibraryEventRefresh() {
    if (isDisposed) return false;
    appLogger.d('DiscoverProvider: refreshing after server library change');
    unawaited(load());
    return true;
  }

  Future<void> _loadOnce() async {
    var outcome = DiscoverRefreshOutcome.cancelled;
    var passClearedExceptionBoundary = false;
    List<MediaItem>? systemShelfPassToken;
    // Observations are staged with the pass, not recorded as each leg lands:
    // suppressing a patch whose fresh row is then discarded or rolled back
    // would leave an older snapshot on screen with nothing to correct it.
    final pendingObservations = <({MediaItem item, String? clientScope})>[];
    final observedServerIds = <String>{};
    // Assigned inside the try, after the preparatory awaits, so the watermark
    // brackets the network calls rather than the whole method.
    ({int watermark, Object epoch})? observation;
    final succeededServerIds = <String>{};
    final failedServerIds = <String>{};
    final cancelledServerIds = <String>{};
    final previousOnDeck = _onDeck;
    final previousHubs = _hubs;
    final previousHasMoreContinueWatching = _hasMoreContinueWatching;
    final previousLoadedOnDeckServerIds = _loadedOnDeckServerIds;
    final previousContinueWatchingCopies = _continueWatchingCopies;
    final previousLoadedHubServerIds = _loadedHubServerIds;
    final previousOnDeckState = _onDeckState;
    final previousHubsState = _hubsState;
    final previousLoadGeneration = _loadGeneration;
    final previousCommitRevision = _commitRevision;
    var expectedCommitRevision = previousCommitRevision;
    var onDeckFetchCompleted = false;
    var hubFetchCompleted = false;
    var replacedOnDeck = false;
    // Recommendation rows wait for this pass's own rows before joining them.
    final hubsSettled = Completer<void>();

    // Shared tail of every settled hub pass: classify the outcome, bump the
    // load generation when a replaced on-deck committed, and mark the pass as
    // having cleared the exception boundary.
    void settlePassOutcome() {
      outcome = _refreshOutcome(
        succeededServerIds: succeededServerIds,
        failedServerIds: failedServerIds,
        cancelledServerIds: cancelledServerIds,
        cancelled: isProfileBinding(),
      );
      if (replacedOnDeck &&
          previousOnDeck.isEmpty &&
          _onDeck.isNotEmpty &&
          outcome != DiscoverRefreshOutcome.failed &&
          outcome != DiscoverRefreshOutcome.cancelled) {
        ++_loadGeneration;
      }
      passClearedExceptionBoundary = true;
    }

    try {
      // Yield to the microtask queue before the first notify so a load()
      // kicked off during build (the screen's initState) doesn't mark
      // listening widgets dirty mid-build.
      await null;
      if (isDisposed || isProfileBinding()) return;
      ++_contentRevision;
      appLogger.d('DiscoverProvider: loading content from all servers');
      _onDeckState = DiscoverLoadState.loading;
      _hubsState = DiscoverLoadState.loading;
      _errorMessage = null;
      safeNotifyListeners();

      if (!_multiServer.hasConnectedServers) throw Exception('No servers available');

      await _hiddenLibraries.ensureInitialized();
      if (isDisposed) return;
      _lastSeenHiddenKeys = Set.of(_hiddenLibraries.hiddenLibraryKeys);

      final settings = await SettingsService.getInstance();
      if (isDisposed) return;
      final useGlobalHubs = settings.read(SettingsService.useGlobalHubs);
      final aggregation = _multiServer.aggregationService;

      // On-deck and hubs fetch in parallel; on-deck is published as soon as
      // it lands so the hero renders while hubs are still loading.
      //
      // The watermark is captured immediately before the requests, after
      // every preparatory await: a patch recorded later has a higher sequence
      // and must survive this pass's observations.
      observation = _beginObservation();
      final onDeckFuture = aggregation.getOnDeckFromAllServers(
        limit: _continueWatchingProbeLimit,
        hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
      );
      final hubsFuture = aggregation.getHubsFromAllServers(
        hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
        useGlobalHubs: useGlobalHubs,
        includePlaybackHubs: false,
      );
      _watchRecommendationsSetting();
      if (_recommendationsOnHome) {
        _startRecommendations(
          aggregation.getRecommendationHubsFromAllServers(hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys),
          after: hubsSettled.future,
        );
      }

      // A pass in which zero servers succeeded is never authoritative: it
      // must not wipe existing content, and it may only commit "loaded,
      // empty" when the failure is settled — not a client-side abort
      // (teardown mid-fetch) and not mid-binding. In both of those cases a
      // follow-up load is guaranteed (binding-settle prime, or
      // syncToOnlineServers falling through to load() while not loaded).
      final fetchedOnDeck = await onDeckFuture;
      onDeckFetchCompleted = true;
      succeededServerIds.addAll(fetchedOnDeck.succeededServerIds);
      failedServerIds.addAll(fetchedOnDeck.failedServerIds);
      cancelledServerIds.addAll(fetchedOnDeck.cancelledServerIds);
      pendingObservations.addAll(fetchedOnDeck.observedItems);
      observedServerIds.addAll(fetchedOnDeck.succeededServerIds);
      if (isDisposed) return;
      if (fetchedOnDeck.succeededServerIds.isEmpty && _onDeck.isNotEmpty) {
        // Keep the stale rows; the empty succeeded set makes the next status
        // emission refetch every server.
        appLogger.w('DiscoverProvider: on-deck pass failed on all servers; keeping previous items');
        _onDeckState = DiscoverLoadState.loaded;
        _loadedOnDeckServerIds = _authoritativeSucceededServerIds(
          fetchedOnDeck.succeededServerIds,
          fetchedOnDeck.failedServerIds,
          fetchedOnDeck.cancelledServerIds,
        );
        safeNotifyListeners();
      } else if (fetchedOnDeck.succeededServerIds.isEmpty &&
          (fetchedOnDeck.cancelledServerIds.isNotEmpty || isProfileBinding())) {
        // Disrupted with nothing to show yet: stay in loading so the screen
        // keeps its skeleton instead of flashing the empty placeholder.
        // Don't return — the hubs fetch is still in flight below.
        appLogger.d('DiscoverProvider: on-deck pass disrupted with no prior content; keeping loading state');
      } else {
        _applyOnDeck(fetchedOnDeck.items, copies: fetchedOnDeck.copies);
        ++expectedCommitRevision;
        replacedOnDeck = true;
        _onDeckState = DiscoverLoadState.loaded;
        _loadedOnDeckServerIds = _authoritativeSucceededServerIds(
          fetchedOnDeck.succeededServerIds,
          fetchedOnDeck.failedServerIds,
          fetchedOnDeck.cancelledServerIds,
        );
        systemShelfPassToken = List<MediaItem>.unmodifiable(_onDeck);
        safeNotifyListeners();
      }

      final fetchedHubs = await hubsFuture;
      hubFetchCompleted = true;
      succeededServerIds.addAll(fetchedHubs.succeededServerIds);
      failedServerIds.addAll(fetchedHubs.failedServerIds);
      pendingObservations.addAll(fetchedHubs.observedItems);
      observedServerIds.addAll(fetchedHubs.succeededServerIds);
      cancelledServerIds.addAll(fetchedHubs.cancelledServerIds);
      if (isDisposed) return;

      if (fetchedHubs.succeededServerIds.isEmpty && _hubs.isNotEmpty) {
        appLogger.w('DiscoverProvider: hub pass failed on all servers; keeping previous hubs');
        _hubsState = DiscoverLoadState.loaded;
        _loadedHubServerIds = _authoritativeSucceededServerIds(
          fetchedHubs.succeededServerIds,
          fetchedHubs.failedServerIds,
          fetchedHubs.cancelledServerIds,
        );
        safeNotifyListeners();
        settlePassOutcome();
        return;
      }
      if (fetchedHubs.succeededServerIds.isEmpty && (fetchedHubs.cancelledServerIds.isNotEmpty || isProfileBinding())) {
        appLogger.d('DiscoverProvider: hub pass disrupted with no prior content; keeping loading state');
        settlePassOutcome();
        return;
      }

      final freshHubs = _filterDiscoverHubs(fetchedHubs.hubs);
      // Recommendation rows already on screen stay until their next read
      // lands, so a refresh does not make them blink out and back.
      final filteredHubs = [
        ...freshHubs,
        ...withoutRecommendationsShownOnHome([
          for (final hub in _hubs)
            if (hub.personalRecommendations && fetchedHubs.succeededServerIds.contains(hub.serverId)) hub,
        ], freshHubs).kept,
      ];
      sortMediaHubsByLibraryOrder(filteredHubs, _libraries.libraries);

      appLogger.d('DiscoverProvider: ${_onDeck.length} on-deck items, ${filteredHubs.length} hubs');
      _replaceHubs(filteredHubs);
      ++expectedCommitRevision;
      _hubsState = DiscoverLoadState.loaded;
      _loadedHubServerIds = _authoritativeSucceededServerIds(
        fetchedHubs.succeededServerIds,
        fetchedHubs.failedServerIds,
        fetchedHubs.cancelledServerIds,
      );
      _hubsLoadedAt = _now();
      // Credit this committed pass so a push event landing moments later
      // defers to the cooldown's trailing edge instead of refetching.
      _libraryEventPacer.notePass();
      settlePassOutcome();
      safeNotifyListeners();
    } catch (e) {
      if (isDisposed) return;
      outcome = isProfileBinding() ? DiscoverRefreshOutcome.cancelled : DiscoverRefreshOutcome.failed;
      appLogger.e('Failed to load discover content', error: e);
      final hadPriorContent = previousOnDeck.isNotEmpty || previousHubs.isNotEmpty;
      if (!hadPriorContent) {
        _errorMessage = e.toString();
        _onDeckState = DiscoverLoadState.error;
        _hubsState = DiscoverLoadState.error;
        safeNotifyListeners();
        return;
      }

      if (_commitRevision == expectedCommitRevision) {
        _replaceOnDeck(
          _withoutHiddenLibraries(previousOnDeck, _hiddenLibraries.hiddenLibraryKeys),
          hasMore: previousHasMoreContinueWatching,
        );
        _continueWatchingCopies = previousContinueWatchingCopies;
        _keepContinueWatchingCopies((item) => _isInVisibleLibrary(item, _hiddenLibraries.hiddenLibraryKeys));
        _replaceHubs(_hubsWithoutHiddenLibraries(previousHubs, _hiddenLibraries.hiddenLibraryKeys));
        _loadedOnDeckServerIds = Set<String>.of(previousLoadedOnDeckServerIds);
        _loadedHubServerIds = Set<String>.of(previousLoadedHubServerIds);
        _onDeckState = previousOnDeckState;
        _hubsState = previousHubsState;
        _loadGeneration = previousLoadGeneration;
      } else {
        _filterCurrentContentForHiddenLibraries();
      }

      final hiddenServerIds = _serverIdsForLibraryKeys(_hiddenLibraries.hiddenLibraryKeys);
      if (!onDeckFetchCompleted) {
        _loadedOnDeckServerIds = {};
      } else {
        _loadedOnDeckServerIds = Set<String>.of(_loadedOnDeckServerIds)
          ..removeAll(failedServerIds)
          ..removeAll(cancelledServerIds);
      }
      if (!hubFetchCompleted) {
        _loadedHubServerIds = {};
      } else {
        _loadedHubServerIds = Set<String>.of(_loadedHubServerIds)
          ..removeAll(failedServerIds)
          ..removeAll(cancelledServerIds);
      }
      _loadedOnDeckServerIds = Set<String>.of(_loadedOnDeckServerIds)..removeAll(hiddenServerIds);
      _loadedHubServerIds = Set<String>.of(_loadedHubServerIds)..removeAll(hiddenServerIds);
      _errorMessage = null;
      _onDeckState = DiscoverLoadState.loaded;
      _hubsState = DiscoverLoadState.loaded;
      safeNotifyListeners();
    } finally {
      hubsSettled.complete();
      _lastOutcome = outcome;
      if (passClearedExceptionBoundary && _commitRevision == expectedCommitRevision && !isDisposed) {
        _recordObservations(observation, pendingObservations, observedServerIds);
        if (systemShelfPassToken != null) unawaited(_syncSystemShelf(systemShelfPassToken));
      }
      if (!isDisposed) _retryIncompleteHomeReads();
    }
  }

  /// Fetch Continue Watching + hubs from [serverIds] only (servers that came
  /// online after the last full pass) and merge them into the loaded state.
  /// Failures keep the loaded state and leave the ids un-loaded, so the next
  /// status emission retries them.
  Future<void> _loadDeltaOnce(Set<String> serverIds) async {
    ++_contentRevision;
    // A full pass may have covered these ids while they sat in the queue.
    final ids = serverIds.difference(_fullyLoadedServerIds);
    final onDeckIds = ids.difference(_loadedOnDeckServerIds);
    final hubIds = ids.difference(_loadedHubServerIds);
    if (onDeckIds.isEmpty && hubIds.isEmpty) return;
    appLogger.d('DiscoverProvider: merging content from newly-online servers $ids (onDeck=$onDeckIds, hubs=$hubIds)');

    try {
      await _hiddenLibraries.ensureInitialized();
      if (isDisposed) return;

      final settings = await SettingsService.getInstance();
      if (isDisposed) return;
      final useGlobalHubs = settings.read(SettingsService.useGlobalHubs);
      final aggregation = _multiServer.aggregationService;

      final observation = _beginObservation();
      final Future<OnDeckAggregationResult?> onDeckFuture = onDeckIds.isEmpty
          ? Future<OnDeckAggregationResult?>.value()
          : aggregation.getOnDeckFromAllServers(
              limit: _continueWatchingProbeLimit,
              hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
              serverIds: onDeckIds,
            );
      final Future<HubAggregationResult?> hubsFuture = hubIds.isEmpty
          ? Future<HubAggregationResult?>.value()
          : aggregation.getHubsFromAllServers(
              hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
              useGlobalHubs: useGlobalHubs,
              includePlaybackHubs: false,
              serverIds: hubIds,
            );

      final hubsSettled = Completer<void>();
      if (hubIds.isNotEmpty && _recommendationsOnHome) {
        _startRecommendations(
          aggregation.getRecommendationHubsFromAllServers(
            hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
            serverIds: hubIds,
          ),
          after: hubsSettled.future,
        );
      }
      final OnDeckAggregationResult? freshOnDeck;
      final HubAggregationResult? freshHubs;
      try {
        freshOnDeck = await onDeckFuture;
        freshHubs = await hubsFuture;
      } finally {
        hubsSettled.complete();
      }
      if (isDisposed) return;
      // Staged, not recorded here: the merge below can still throw, and the
      // catch keeps the previous rows. Suppressing patches against rows that
      // were then discarded would strand an older snapshot on screen.
      final pendingObservations = <({MediaItem item, String? clientScope})>[];
      final observedServerIds = <String>{};

      if (freshOnDeck != null) {
        final hadMore = _hasMoreContinueWatching;
        final mergedOnDeck = await aggregation.mergeContinueWatching(
          _onDeck,
          freshOnDeck.items,
          existingCopies: _continueWatchingCopies,
          freshCopies: freshOnDeck.copies,
          limit: _continueWatchingProbeLimit,
        );
        if (isDisposed) return;
        _applyOnDeck(mergedOnDeck.items, copies: mergedOnDeck.copies);
        // The stored list is already trimmed, so the merge can't see old items
        // past the cap — a previously-true "more" affordance stays true.
        if (hadMore) _hasMoreContinueWatching = true;
        _loadedOnDeckServerIds = {..._loadedOnDeckServerIds, ...freshOnDeck.succeededServerIds}
          ..removeAll(freshOnDeck.failedServerIds)
          ..removeAll(freshOnDeck.cancelledServerIds);
        // No _loadGeneration bump: a delta behaves like the background Continue
        // Watching refresh (the hero clamps instead of resetting).
      }

      if (freshHubs != null) {
        final succeededHubIds = freshHubs.succeededServerIds;
        final serverHubs = _filterDiscoverHubs(freshHubs.hubs);
        final mergedHubs = [
          ..._hubs.where((hub) => hub.serverId == null || !succeededHubIds.contains(hub.serverId)),
          ...serverHubs,
          ...withoutRecommendationsShownOnHome([
            for (final hub in _hubs)
              if (hub.personalRecommendations && succeededHubIds.contains(hub.serverId)) hub,
          ], serverHubs).kept,
        ];
        sortMediaHubsByLibraryOrder(mergedHubs, _libraries.libraries);
        _replaceHubs(mergedHubs);
        _loadedHubServerIds = {..._loadedHubServerIds, ...succeededHubIds}
          ..removeAll(freshHubs.failedServerIds)
          ..removeAll(freshHubs.cancelledServerIds);
      }

      if (freshOnDeck != null) {
        pendingObservations.addAll(freshOnDeck.observedItems);
        observedServerIds.addAll(freshOnDeck.succeededServerIds);
      }
      if (freshHubs != null) {
        pendingObservations.addAll(freshHubs.observedItems);
        observedServerIds.addAll(freshHubs.succeededServerIds);
      }
      _recordObservations(observation, pendingObservations, observedServerIds);

      appLogger.d('DiscoverProvider: ${_onDeck.length} on-deck items, ${_hubs.length} hubs after merging $ids');
      safeNotifyListeners();
      unawaited(_syncSystemShelf(_onDeck));
    } catch (e) {
      if (isDisposed) return;
      // Keep the loaded state — stale rows beat an error flash.
      appLogger.w('DiscoverProvider: delta load failed for $ids', error: e);
    }
  }

  /// Runs one recommendation read: once it has answered and the pass that
  /// started it has settled its own rows ([after]), its rows replace the
  /// recommendation rows shown for each server that answered.
  void _startRecommendations(Future<RecommendationAggregationResult> read, {required Future<void> after}) {
    final generation = ++_recommendationsGeneration;
    final observation = _beginObservation();
    late final Future<void> run;
    run = () async {
      try {
        final (result, _) = await (read, after).wait;
        if (isDisposed) return;
        _applyRecommendations(result, generation: generation, observation: observation);
      } catch (e, stackTrace) {
        if (!isDisposed) appLogger.w('DiscoverProvider: recommendations not applied', error: e, stackTrace: stackTrace);
      } finally {
        _recommendationsInFlight.remove(run);
      }
    }();
    _recommendationsInFlight.add(run);
  }

  void _applyRecommendations(
    RecommendationAggregationResult result, {
    required int generation,
    required ({int watermark, Object epoch})? observation,
  }) {
    // Only once Home has rows of its own (a failed first load shows its
    // error, not a lone recommendation row), and never over a newer read.
    if (_hubsState != DiscoverLoadState.loaded) return;
    final servers = {
      for (final serverId in result.settledServerIds)
        if ((_recommendationsAppliedGeneration[serverId] ?? 0) < generation) serverId,
    };
    if (servers.isEmpty) return;
    for (final serverId in servers) {
      _recommendationsAppliedGeneration[serverId] = generation;
    }
    final base = [
      for (final hub in _hubs)
        if (!(hub.personalRecommendations && servers.contains(hub.serverId))) hub,
    ];
    final fresh = _hubsWithoutHiddenLibraries(
      _filterDiscoverHubs([
        for (final hub in result.hubs)
          if (servers.contains(hub.serverId)) hub,
      ]),
      _hiddenLibraries.hiddenLibraryKeys,
    );
    final beside = withoutRecommendationsShownOnHome(fresh, base);
    appLogger.i(
      'Home: recommendation rows shown: ${beside.kept.length}'
      '${beside.dropped == 0 ? '' : ' (${beside.dropped} left out as already on Home)'}',
    );
    final hadRows = _hubs.length != base.length;
    if (!hadRows && beside.kept.isEmpty) return;
    final merged = [...base, ...beside.kept];
    sortMediaHubsByLibraryOrder(merged, _libraries.libraries);
    _replaceHubs(merged);
    _recordObservations(observation, [
      for (final row in result.observedItems)
        if (servers.contains(row.item.serverId)) row,
    ], servers);
    safeNotifyListeners();
  }

  /// Playback-progress hubs duplicate the top Continue Watching row.
  List<MediaHub> _filterDiscoverHubs(List<MediaHub> hubs) {
    return hubs.where((hub) {
      final hubId = hub.identifier?.toLowerCase() ?? '';
      final title = hub.title.toLowerCase();
      return !hubId.contains('ondeck') &&
          !hubId.contains('continue') &&
          !hubId.contains('nextup') &&
          !title.contains('continue watching') &&
          !title.contains('on deck') &&
          !title.contains('next up');
    }).toList();
  }

  Set<String> _authoritativeSucceededServerIds(
    Set<String> succeededServerIds,
    Set<String> failedServerIds,
    Set<String> cancelledServerIds,
  ) {
    return Set<String>.of(succeededServerIds)
      ..removeAll(failedServerIds)
      ..removeAll(cancelledServerIds);
  }

  List<MediaItem> _withoutHiddenLibraries(List<MediaItem> items, Set<String> hiddenLibraryKeys) {
    if (hiddenLibraryKeys.isEmpty) return items;
    return items.where((item) => _isInVisibleLibrary(item, hiddenLibraryKeys)).toList();
  }

  static bool _isInVisibleLibrary(MediaItem item, Set<String> hiddenLibraryKeys) {
    final libraryKey = item.hidingLibraryGlobalKey;
    return libraryKey == null || !hiddenLibraryKeys.contains(libraryKey);
  }

  List<MediaHub> _hubsWithoutHiddenLibraries(List<MediaHub> hubs, Set<String> hiddenLibraryKeys) {
    if (hiddenLibraryKeys.isEmpty) return hubs;
    final filteredHubs = <MediaHub>[];
    for (final hub in hubs) {
      final filteredItems = hub.items.where((item) {
        var libraryKey = item.hidingLibraryGlobalKey;
        final source = item.raw?[MediaItem.sourceLibraryKey];
        final libraryId = item.libraryId ?? (source is String && source.isNotEmpty ? source : null);
        final serverId = item.serverId ?? hub.serverId;
        if (libraryKey == null && libraryId != null && serverId != null) {
          libraryKey = buildGlobalKey(ServerId(serverId), libraryId);
        }
        return libraryKey == null || !hiddenLibraryKeys.contains(libraryKey);
      }).toList();
      if (filteredItems.isNotEmpty) {
        filteredHubs.add(
          filteredItems.length == hub.items.length
              ? hub
              : hub.copyWith(items: filteredItems, size: filteredItems.length),
        );
      }
    }
    return filteredHubs;
  }

  Set<String> _serverIdsForLibraryKeys(Set<String> libraryKeys) {
    final serverIds = <String>{};
    for (final key in libraryKeys) {
      final parsed = parseGlobalKey(key);
      if (parsed != null) serverIds.add(parsed.serverId);
    }
    return serverIds;
  }

  void _filterCurrentContentForHiddenLibraries() {
    final hiddenLibraryKeys = _hiddenLibraries.hiddenLibraryKeys;
    final filteredOnDeck = _withoutHiddenLibraries(_onDeck, hiddenLibraryKeys);
    if (filteredOnDeck.length != _onDeck.length) {
      _replaceOnDeck(filteredOnDeck, hasMore: _hasMoreContinueWatching);
    }
    if (hiddenLibraryKeys.isNotEmpty) {
      _keepContinueWatchingCopies((item) => _isInVisibleLibrary(item, hiddenLibraryKeys));
    }
    final filteredHubs = _hubsWithoutHiddenLibraries(_hubs, hiddenLibraryKeys);
    if (!listEquals(filteredHubs, _hubs)) {
      _replaceHubs(filteredHubs);
    }
  }

  /// Background refresh of Continue Watching only. Concurrent events coalesce
  /// into the active request plus at most one trailing fresh request.
  Future<void> refreshContinueWatching() {
    final active = _continueWatchingRefreshFuture;
    if (active != null) {
      _continueWatchingRefreshQueued = true;
      return active;
    }
    late final Future<void> refresh;
    refresh = _runContinueWatchingRefreshes().whenComplete(() {
      if (identical(_continueWatchingRefreshFuture, refresh)) {
        _continueWatchingRefreshFuture = null;
      }
    });
    _continueWatchingRefreshFuture = refresh;
    return refresh;
  }

  Future<void> _runContinueWatchingRefreshes() async {
    do {
      _continueWatchingRefreshQueued = false;
      await _refreshContinueWatchingOnce();
    } while (_continueWatchingRefreshQueued && !isDisposed);
  }

  Future<void> _refreshContinueWatchingOnce() async {
    try {
      if (isProfileBinding() || !_multiServer.hasConnectedServers) return;
      final revision = _contentRevision;
      final hiddenKeys = Set<String>.of(_hiddenLibraries.hiddenLibraryKeys);
      final observation = _beginObservation();
      final fetched = await _multiServer.aggregationService.getOnDeckFromAllServers(
        limit: _continueWatchingProbeLimit,
        hiddenLibraryKeys: hiddenKeys,
      );
      if (isDisposed) return;
      if (revision != _contentRevision) {
        // A newer mutation landed while this was in flight, so these rows are
        // discarded — recording them would suppress patches against data the
        // user never sees.
        _continueWatchingRefreshQueued = true;
        return;
      }
      _loadedOnDeckServerIds = _authoritativeSucceededServerIds(
        fetched.succeededServerIds,
        fetched.failedServerIds,
        fetched.cancelledServerIds,
      );
      if (fetched.succeededServerIds.isEmpty) {
        safeNotifyListeners();
        return;
      }
      _applyOnDeck(fetched.items, copies: fetched.copies);
      _recordObservations(observation, fetched.observedItems, fetched.succeededServerIds);
      safeNotifyListeners();
      unawaited(_syncSystemShelf(_onDeck));
    } catch (e) {
      appLogger.w('Failed to refresh Continue Watching', error: e);
    }
  }

  /// The full unlimited Continue Watching list for the hub's load-more path.
  Future<List<MediaItem>> loadAllContinueWatching() async {
    if (!_multiServer.hasConnectedServers) return const [];
    await _hiddenLibraries.ensureInitialized();
    if (isDisposed) return const [];
    final observation = _beginObservation();
    final fetched = await _multiServer.aggregationService.getOnDeckFromAllServers(
      hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
    );
    // "View All" renders through the same overlay as the row it expands, so
    // it has to reconcile too or the stale patch simply reappears there.
    _recordObservations(observation, fetched.observedItems, fetched.succeededServerIds);
    // Its rows past the preview open the same copy picker as the row's.
    _continueWatchingCopies = {..._continueWatchingCopies, ...fetched.copies};
    return fetched.items;
  }

  /// Reconcile [source] after the user acted on it: returned from its player
  /// or detail screen, or edited it in place.
  ///
  /// Continue Watching rows are written only by the on-deck fetch, so a row
  /// (or a copy it absorbed) reconciles through [refreshContinueWatching].
  /// Splicing the `fetchItem` copy into the row raced the refresh Home starts
  /// on route return, and the two shapes carry different artwork (Plex's full
  /// metadata has a season poster older servers' hub rows lack), so the poster
  /// flipped with whichever response landed last (#2950). Ordinary hubs have
  /// no competing refetch and keep the in-place swap, fetched through the
  /// source server only when one of them holds the item.
  Future<void> updateItem(MediaItem source) async {
    if (isDisposed) return;
    final serverId = source.serverId;
    if (serverId == null) return;
    final globalKey = source.globalKey;

    await Future.wait([
      if (_isInContinueWatching(globalKey)) refreshContinueWatching(),
      if (_hubs.any((hub) => hub.items.any((item) => item.globalKey == globalKey)))
        _refreshHubItem(ServerId(serverId), source.id, globalKey),
    ]);
  }

  bool _isInContinueWatching(String globalKey) =>
      _onDeck.followedBy(_continueWatchingCopyItems).any((item) => item.globalKey == globalKey);

  Future<void> _refreshHubItem(ServerId serverId, String itemId, String globalKey) async {
    try {
      final updated = await _multiServer.getClientForServer(serverId)?.fetchItem(itemId);
      if (updated == null || isDisposed) return;
      _replaceInHubs(globalKey, updated);
      safeNotifyListeners();
    } catch (_) {
      // Silently fail — the item will refresh on the next full reload.
    }
  }

  void _replaceInHubs(String sourceGlobalKey, MediaItem updatedItem) {
    List<MediaHub>? updatedHubs;
    for (var i = 0; i < _hubs.length; i++) {
      final hub = _hubs[i];
      final itemIndex = hub.items.indexWhere((item) => item.globalKey == sourceGlobalKey);
      if (itemIndex != -1) {
        final newItems = List<MediaItem>.from(hub.items);
        newItems[itemIndex] = updatedItem;
        (updatedHubs ??= List.of(_hubs))[i] = hub.copyWith(items: newItems);
      }
    }
    if (updatedHubs != null) _replaceHubs(updatedHubs);
  }

  void _applyOnDeck(List<MediaItem> fetched, {required Map<String, List<MediaItem>> copies}) {
    final hasMore = fetched.length > continueWatchingPreviewLimit;
    _continueWatchingCopies = copies;
    _replaceOnDeck(hasMore ? fetched.take(continueWatchingPreviewLimit).toList() : fetched, hasMore: hasMore);
  }

  /// Drop copies failing [keep] from every row's copy group; a group left
  /// with a single copy is no longer a choice and goes.
  void _keepContinueWatchingCopies(bool Function(MediaItem item) keep) {
    if (_continueWatchingCopies.isEmpty) return;
    _continueWatchingCopies = {
      for (final MapEntry(:key, :value) in _continueWatchingCopies.entries)
        if (value.where(keep).toList() case final kept when kept.length > 1) key: kept,
    };
  }

  /// A row shows the copy last played on this device, so progress on a copy
  /// the row absorbed swaps that copy in at its new offset: the pick the next
  /// fetch's dedup makes anyway. Returns whether a row changed.
  bool _promoteContinueWatchingCopy(String globalKey, int viewOffset) {
    for (var i = 0; i < _onDeck.length; i++) {
      final row = _onDeck[i];
      final copies = _continueWatchingCopies[row.globalKey];
      final copyIndex = copies?.indexWhere((copy) => copy.globalKey == globalKey) ?? -1;
      if (copyIndex == -1) continue;
      final promoted = copies![copyIndex].copyWith(viewOffsetMs: viewOffset);
      _continueWatchingCopies = {
        for (final entry in _continueWatchingCopies.entries)
          if (entry.key != row.globalKey) entry.key: entry.value,
        promoted.globalKey: [
          for (final copy in copies)
            if (copy.globalKey == globalKey) promoted else if (copy.globalKey == row.globalKey) row else copy,
        ],
      };
      _replaceOnDeck(List.of(_onDeck)..[i] = promoted, hasMore: _hasMoreContinueWatching);
      return true;
    }
    return false;
  }

  void _replaceOnDeck(List<MediaItem> onDeck, {required bool hasMore}) {
    _onDeck = onDeck;
    _hasMoreContinueWatching = hasMore;
    ++_commitRevision;
  }

  void _replaceHubs(List<MediaHub> hubs) {
    _hubs = hubs;
    ++_commitRevision;
  }

  // --- Event reactions -----------------------------------------------------

  /// Watch on-deck items and their parent shows/seasons (an episode's watch
  /// flip changes what Continue Watching should show for its series), plus
  /// the copies the rows absorbed.
  Set<String>? get _watchedIds => hierarchicalEventIds(_onDeck.followedBy(_continueWatchingCopyItems));

  Set<String>? get _watchedGlobalKeys => hierarchicalEventGlobalKeys(_onDeck.followedBy(_continueWatchingCopyItems));

  Iterable<MediaItem> get _continueWatchingCopyItems => _continueWatchingCopies.values.expand((copies) => copies);

  void _onWatchStateChanged(WatchStateEvent event) {
    if (event.changeType == WatchStateChangeType.progressUpdate && event.isNowWatched != true) {
      final viewOffset = event.viewOffset;
      final index = _onDeck.indexWhere((item) => item.globalKey == event.globalKey);
      if (viewOffset != null && index != -1 && _onDeck[index].viewOffsetMs != viewOffset) {
        _replaceOnDeck(
          List.of(_onDeck)..[index] = _onDeck[index].copyWith(viewOffsetMs: viewOffset),
          hasMore: _hasMoreContinueWatching,
        );
        safeNotifyListeners();
        unawaited(_syncSystemShelf(_onDeck));
      } else if (viewOffset != null && index == -1 && _promoteContinueWatchingCopy(event.globalKey, viewOffset)) {
        safeNotifyListeners();
        unawaited(_syncSystemShelf(_onDeck));
      }
      return;
    }

    final serverId = event.serverId.value;
    if (event.changeType == WatchStateChangeType.removedFromContinueWatching) {
      _evictFromOnDeck((item) => item.serverId == serverId && item.id == event.itemId);
    } else if (event.changeType == WatchStateChangeType.watched ||
        (event.changeType == WatchStateChangeType.progressUpdate && event.isNowWatched == true)) {
      // Finished items have no business in Continue Watching, so drop the row
      // now instead of waiting a round trip for the refetch below to confirm
      // it. Marking a season or show watched takes its on-deck episode with
      // it, matching the parent-aware filter this subscription uses — the
      // series' successor comes back from the refetch (#1812).
      _evictFromOnDeck(
        (item) =>
            item.serverId == serverId &&
            (item.id == event.itemId || item.parentId == event.itemId || item.grandparentId == event.itemId),
      );
    }
    unawaited(refreshContinueWatching());
  }

  void _evictFromOnDeck(bool Function(MediaItem item) matches) {
    _keepContinueWatchingCopies((item) => !matches(item));
    final remaining = _onDeck.where((item) => !matches(item)).toList();
    if (remaining.length == _onDeck.length) return;
    _replaceOnDeck(remaining, hasMore: _hasMoreContinueWatching);
    safeNotifyListeners();
    unawaited(_syncSystemShelf(_onDeck));
  }

  /// Everything on screen: the Continue Watching row plus every hub row.
  Iterable<MediaItem> get _visibleItems => _onDeck.followedBy(_hubs.expand((hub) => hub.items));

  /// Deletions can affect any visible list, so the filter covers on-deck and
  /// hub items plus their parents (a deleted season/show takes its visible
  /// episodes with it), and the copies behind Continue Watching rows.
  Set<String>? get _deletionIds => hierarchicalEventIds(_visibleItems.followedBy(_continueWatchingCopyItems));

  Set<String>? get _deletionGlobalKeys =>
      hierarchicalEventGlobalKeys(_visibleItems.followedBy(_continueWatchingCopyItems));

  void _onDeletion(DeletionEvent event) {
    // On-deck and hubs are server-backed: a download-only deletion leaves the
    // server item in place, so it must not evict anything here.
    if (event.isDownloadOnly) return;

    // Scoped to the emitting server: backend-native ids (Plex rating keys are
    // small sequential integers) routinely collide across servers, and push
    // removals made this an automated event (#1646).
    bool affected(MediaItem item) =>
        item.serverId == event.serverId.value &&
        (item.id == event.itemId || item.parentId == event.itemId || item.grandparentId == event.itemId);

    var changed = false;
    _keepContinueWatchingCopies((item) => !affected(item));
    final remainingOnDeck = _onDeck.where((item) => !affected(item)).toList();
    if (remainingOnDeck.length != _onDeck.length) {
      _replaceOnDeck(remainingOnDeck, hasMore: _hasMoreContinueWatching);
      changed = true;
    }
    List<MediaHub>? updatedHubs;
    for (var i = 0; i < _hubs.length; i++) {
      final hub = _hubs[i];
      final newItems = hub.items.where((item) => !affected(item)).toList();
      if (newItems.length != hub.items.length) {
        (updatedHubs ??= List.of(_hubs))[i] = hub.copyWith(items: newItems);
      }
    }
    if (updatedHubs != null) {
      _replaceHubs(updatedHubs);
      changed = true;
    }
    if (changed) safeNotifyListeners();
    if (event.origin == DeletionOrigin.local) {
      unawaited(refreshContinueWatching());
    }
  }

  void _onHiddenLibrariesChanged() {
    final currentKeys = _hiddenLibraries.hiddenLibraryKeys;
    if (currentKeys.length == _lastSeenHiddenKeys.length && currentKeys.containsAll(_lastSeenHiddenKeys)) {
      return;
    }
    _lastSeenHiddenKeys = Set.of(currentKeys);
    unawaited(load());
  }

  void _onLibrariesChanged() {
    final currentKeys = _libraryOrderKeys();
    if (listEquals(currentKeys, _lastSeenLibraryOrderKeys)) return;
    _lastSeenLibraryOrderKeys = currentKeys;
    if (_hubs.isEmpty) return;

    final sortedHubs = List<MediaHub>.from(_hubs);
    if (!sortMediaHubsByLibraryOrder(sortedHubs, _libraries.libraries)) return;
    _replaceHubs(sortedHubs);
    safeNotifyListeners();
  }

  List<String> _libraryOrderKeys() => [for (final library in _libraries.libraries) library.globalKey];

  // --- Platform launcher shelf ----------------------------------------------

  /// The launcher shelf admitted this profile again after withholding it (its
  /// PIN or the ask-on-open setting changed): republish what is loaded.
  void _onShelfPublicationResumed(String owner) {
    if (isDisposed || owner != profileId) return;
    unawaited(_syncSystemShelf(_onDeck));
  }

  /// Sync Continue Watching to the platform launcher shelf. Rapid updates
  /// coalesce: a sync that arrives while one is in flight queues exactly one
  /// follow-up pass with the latest items.
  Future<void> _syncSystemShelf(List<MediaItem> onDeck) async {
    if (isDisposed) return;
    final owner = profileId;
    if (owner == null) return;
    _pendingSystemShelfItems = List<MediaItem>.unmodifiable(onDeck);
    if (_systemShelfSyncFuture != null) {
      await _systemShelfSyncFuture;
      return;
    }

    final syncFuture = _drainSystemShelfSyncQueue();
    _systemShelfSyncFuture = syncFuture;
    await syncFuture;
  }

  Future<void> _drainSystemShelfSyncQueue() async {
    final owner = profileId;
    if (owner == null) return;
    try {
      while (_pendingSystemShelfItems != null) {
        final onDeck = _pendingSystemShelfItems!;
        _pendingSystemShelfItems = null;
        if (isDisposed) return;

        try {
          // tvOS pulls Continue Watching itself; hand the Top Shelf extension
          // the current online server sources before publishing items.
          final sourcesOverride = _syncServerSourcesOverride;
          final syncOverride = _syncSystemShelfOverride;
          if (sourcesOverride != null) {
            await sourcesOverride(owner, _onlineShelfSourceClients());
          } else if (syncOverride == null) {
            final settings = await SettingsService.getInstance();
            if (isDisposed) return;
            await SystemShelfService().syncServerSources(
              owner,
              _onlineShelfSourceClients(),
              episodePosterMode: settings.read(SettingsService.episodePosterMode),
            );
          }
          if (isDisposed) return;
          if (syncOverride != null) {
            await syncOverride(owner, onDeck);
            continue;
          }
          final settings = await SettingsService.getInstance();
          if (isDisposed) return;
          final syncableOnDeck = onDeck
              .where((item) {
                final serverId = item.serverId;
                return serverId != null && _multiServer.getClientForServer(ServerId(serverId)) != null;
              })
              .toList(growable: false);
          await SystemShelfService().syncFromContinueWatching(
            owner,
            syncableOnDeck,
            _clientForShelfItem,
            hideSpoilers: settings.read(SettingsService.hideSpoilers),
            episodePosterMode: settings.read(SettingsService.episodePosterMode),
          );
        } catch (e) {
          appLogger.w('Failed to sync system shelf', error: e);
        }
      }
    } finally {
      if (!isDisposed) _systemShelfSyncFuture = null;
    }
  }

  MediaServerClient _clientForShelfItem(ServerId serverId) {
    final direct = _multiServer.getClientForServer(serverId);
    if (direct != null) return direct;
    throw Exception('No owning client available for $serverId');
  }

  List<MediaServerClient> _onlineShelfSourceClients() =>
      _multiServer.serverManager.visibleOnlineClients.values.toList(growable: false);

  // --- Home watch state (Silo) ---------------------------------------------
  //
  // Silo's apps re-read Home when it is shown again, when the app returns,
  // and when the server's event stream says the profile's watch state changed
  // on another device (Silo Android #1009, Silo's Roku app #102); a read that
  // left rows out for a transient reason is read again with a short backoff.
  // Only servers whose client is a [HomeWatchStateClient] (Silo) take part:
  // their rows come from one Home read, so they are re-read alone and
  // replaced in place. Plex, Jellyfin and Emby keep the rules above.

  /// The shortest gap between two re-reads asked by [HomeWatchStateTrigger.shown]
  /// or [HomeWatchStateTrigger.resumed] (desktop windows report a resume on
  /// every focus gain, and a return from a route reports "shown" twice).
  final Duration watchStateShownThrottle;

  /// Watch-state events arriving together become one re-read (foreign
  /// playback reports progress every few seconds).
  final Duration watchStateEventDebounce;

  /// The first retry of an incomplete read waits this long, then twice and
  /// four times as long; [watchStateMaxRetries] in all (Silo Android #1009).
  final Duration watchStateRetryBase;
  static const int watchStateMaxRetries = 3;

  bool _homeVisible = false;
  bool _appForeground = true;
  final Map<String, ({HomeWatchStateClient client, HomeWatchStateWatch watch})> _watchStateWatches = {};
  final Set<String> _watchStateSignalled = {};
  Timer? _watchStateDebounceTimer;
  DateTime? _lastWatchStateRefreshAt;
  Future<void>? _watchStateRefreshFuture;
  final Set<String> _watchStateRefreshQueue = {};
  int _watchStateRetryAttempt = 0;
  Timer? _watchStateRetryTimer;

  /// Home's rows are on screen (the screen reports it: tab shown/hidden, a
  /// route pushed over it or popped). Event streams run only while they are.
  void setHomeVisible(bool visible) {
    if (isDisposed || _homeVisible == visible) return;
    _homeVisible = visible;
    _onWatchStateActivityChanged();
  }

  /// The app is in the foreground (resumed) or backgrounded (hidden/paused).
  void setAppForeground(bool foreground) {
    if (isDisposed || _appForeground == foreground) return;
    _appForeground = foreground;
    _onWatchStateActivityChanged();
  }

  @visibleForTesting
  bool get isWatchingHomeWatchState => _watchStateWatches.isNotEmpty;

  @visibleForTesting
  Set<String> get watchedHomeWatchStateServerIds => _watchStateWatches.keys.toSet();

  bool get _watchStateActive => !isDisposed && _homeVisible && _appForeground;

  void _onWatchStateActivityChanged() {
    if (!_watchStateActive) {
      _watchStateDebounceTimer?.cancel();
      _watchStateSignalled.clear();
      _watchStateRetryTimer?.cancel();
      _watchStateRetryAttempt = 0;
    }
    _syncWatchStateWatches();
  }

  /// The online set changed: merge newly online servers' rows, and start or
  /// stop watch-state streams (a server gone offline or signed out stops).
  void _onOnlineServersChanged(Set<String> onlineServerIds) {
    _dropServersNoLongerInProfile();
    unawaited(syncToOnlineServers(onlineServerIds));
    _syncWatchStateWatches();
  }

  /// Leave out the Continue Watching rows, absorbed copies and hubs of servers
  /// the profile no longer has (a connection switched off or removed). A
  /// server that is only offline stays expected and keeps its rows; nothing is
  /// pruned while the binder is still wiring servers, when the sets are
  /// mid-change.
  void _dropServersNoLongerInProfile() {
    if (isDisposed || isProfileBinding()) return;
    final known = {..._multiServer.serverIds, ..._multiServer.expectedServerIds};
    bool gone(String? serverId) => serverId != null && !known.contains(serverId);
    final onDeck = [
      for (final item in _onDeck)
        if (!gone(item.serverId)) item,
    ];
    final hubs = [
      for (final hub in _hubs)
        if (!gone(hub.serverId)) hub,
    ];
    final droppedRows = onDeck.length != _onDeck.length;
    final droppedHubs = hubs.length != _hubs.length;
    final hadCopies = _continueWatchingCopies.values.expand((c) => c).any((c) => gone(c.serverId));
    if (!droppedRows && !droppedHubs && !hadCopies) return;
    if (droppedRows) _replaceOnDeck(onDeck, hasMore: _hasMoreContinueWatching);
    if (hadCopies) _keepContinueWatchingCopies((item) => !gone(item.serverId));
    if (droppedHubs) _replaceHubs(hubs);
    _loadedOnDeckServerIds = _loadedOnDeckServerIds.where((id) => !gone(id)).toSet();
    _loadedHubServerIds = _loadedHubServerIds.where((id) => !gone(id)).toSet();
    appLogger.i('DiscoverProvider: left out the rows of servers no longer in the profile');
    safeNotifyListeners();
    if (droppedRows) unawaited(_syncSystemShelf(_onDeck));
  }

  /// Online servers whose client can re-read its Home alone, by server id.
  Map<String, HomeWatchStateClient> _watchStateClients({Set<String>? only}) {
    final clients = <String, HomeWatchStateClient>{};
    for (final serverId in _multiServer.onlineServerIds) {
      if (only != null && !only.contains(serverId)) continue;
      final client = _multiServer.getClientForServer(ServerId(serverId));
      if (client is HomeWatchStateClient) clients[serverId] = client as HomeWatchStateClient;
    }
    return clients;
  }

  /// Starts a watch for each online watch-state server while Home is shown
  /// and the app is in the foreground; stops the others (Home hidden, app
  /// backgrounded, server offline or signed out, client replaced).
  void _syncWatchStateWatches() {
    final wanted = _watchStateActive && !isProfileBinding()
        ? _watchStateClients()
        : const <String, HomeWatchStateClient>{};
    for (final serverId in _watchStateWatches.keys.toList()) {
      final entry = _watchStateWatches[serverId]!;
      if (identical(wanted[serverId], entry.client)) continue;
      entry.watch.stop();
      _watchStateWatches.remove(serverId);
    }
    for (final MapEntry(key: serverId, value: client) in wanted.entries) {
      if (_watchStateWatches.containsKey(serverId)) continue;
      final watch = client.watchHomeWatchState((signal) => _onWatchStateSignal(serverId, client, signal));
      if (watch != null) _watchStateWatches[serverId] = (client: client, watch: watch);
    }
  }

  void _stopWatchStateWatches() {
    for (final entry in _watchStateWatches.values) {
      entry.watch.stop();
    }
    _watchStateWatches.clear();
  }

  void _onWatchStateSignal(String serverId, HomeWatchStateClient client, HomeWatchStateSignal signal) {
    if (!_watchStateActive || !identical(_watchStateWatches[serverId]?.client, client)) return;
    appLogger.d('DiscoverProvider: watch state ${signal.name} on a Silo server; re-reading its Home rows');
    _watchStateSignalled.add(serverId);
    _watchStateDebounceTimer?.cancel();
    _watchStateDebounceTimer = Timer(watchStateEventDebounce, () {
      final serverIds = Set<String>.of(_watchStateSignalled);
      _watchStateSignalled.clear();
      unawaited(refreshHomeWatchState(HomeWatchStateTrigger.event, serverIds: serverIds));
    });
  }

  /// Re-reads the Home rows (Continue Watching and hubs) of the online
  /// servers whose Home can be read alone ([HomeWatchStateClient]: Silo),
  /// limited to [serverIds] when given, and replaces their rows in place. A
  /// server whose read fails keeps the rows shown. Runs only while Home is
  /// visible and loaded; a shown/resumed request inside
  /// [watchStateShownThrottle] of the last one, or while a full pass runs,
  /// does nothing (the pass reads those servers anyway). Concurrent requests
  /// join the running re-read, which reads once more for them.
  Future<void> refreshHomeWatchState(HomeWatchStateTrigger trigger, {Set<String>? serverIds}) {
    if (!_watchStateActive || isProfileBinding()) return Future<void>.value();
    if (_onDeckState != DiscoverLoadState.loaded || _hubsState != DiscoverLoadState.loaded) {
      return Future<void>.value();
    }
    final ids = _watchStateClients(only: serverIds).keys.toSet();
    if (ids.isEmpty) return Future<void>.value();
    final userTriggered = trigger == HomeWatchStateTrigger.shown || trigger == HomeWatchStateTrigger.resumed;
    if (userTriggered) {
      if (_loadCoordinator.isFullActive) return Future<void>.value();
      final last = _lastWatchStateRefreshAt;
      if (last != null && _now().difference(last) < watchStateShownThrottle) {
        return _watchStateRefreshFuture ?? Future<void>.value();
      }
    }
    if (trigger != HomeWatchStateTrigger.retry) {
      _watchStateRetryTimer?.cancel();
      _watchStateRetryAttempt = 0;
    }
    _lastWatchStateRefreshAt = _now();
    _watchStateRefreshQueue.addAll(ids);
    final active = _watchStateRefreshFuture;
    if (active != null) return active;
    late final Future<void> run;
    run = _drainWatchStateRefreshes().whenComplete(() {
      if (identical(_watchStateRefreshFuture, run)) _watchStateRefreshFuture = null;
    });
    return _watchStateRefreshFuture = run;
  }

  Future<void> _drainWatchStateRefreshes() async {
    final incomplete = <String>{};
    while (_watchStateRefreshQueue.isNotEmpty && !isDisposed) {
      final serverIds = Set<String>.of(_watchStateRefreshQueue);
      _watchStateRefreshQueue.clear();
      final stillIncomplete = await _refreshHomeWatchStateOnce(serverIds);
      incomplete
        ..removeAll(serverIds)
        ..addAll(stillIncomplete);
    }
    _scheduleWatchStateRetry(incomplete);
  }

  /// After a full pass: a Silo server whose Home read was incomplete is read
  /// again on the same backoff.
  void _retryIncompleteHomeReads() {
    if (!_watchStateActive) return;
    final incomplete = {
      for (final MapEntry(:key, :value) in _watchStateClients().entries)
        if (value.lastHomeReadIncomplete) key,
    };
    _watchStateRetryAttempt = 0;
    _scheduleWatchStateRetry(incomplete);
  }

  void _scheduleWatchStateRetry(Set<String> incomplete) {
    if (isDisposed) return;
    if (incomplete.isEmpty) {
      _watchStateRetryAttempt = 0;
      return;
    }
    if (!_watchStateActive) return;
    if (_watchStateRetryAttempt >= watchStateMaxRetries) {
      appLogger.d('DiscoverProvider: Silo Home rows still incomplete after $watchStateMaxRetries retries');
      _watchStateRetryAttempt = 0;
      return;
    }
    final delay = watchStateRetryBase * (1 << _watchStateRetryAttempt);
    _watchStateRetryAttempt++;
    appLogger.d('DiscoverProvider: Silo Home rows incomplete; reading again in ${delay.inMilliseconds} ms');
    _watchStateRetryTimer?.cancel();
    _watchStateRetryTimer = Timer(delay, () {
      unawaited(refreshHomeWatchState(HomeWatchStateTrigger.retry, serverIds: incomplete));
    });
  }

  /// One re-read of [serverIds]; returns the servers whose read was
  /// incomplete.
  Future<Set<String>> _refreshHomeWatchStateOnce(Set<String> serverIds) async {
    try {
      final revision = _contentRevision;
      await _hiddenLibraries.ensureInitialized();
      if (isDisposed) return const {};
      final settings = await SettingsService.getInstance();
      if (isDisposed || isProfileBinding()) return const {};
      final hiddenKeys = Set<String>.of(_hiddenLibraries.hiddenLibraryKeys);
      final aggregation = _multiServer.aggregationService;
      final observation = _beginObservation();
      final onDeckFuture = aggregation.getOnDeckFromAllServers(
        limit: _continueWatchingProbeLimit,
        hiddenLibraryKeys: hiddenKeys,
        serverIds: serverIds,
      );
      final hubsFuture = aggregation.getHubsFromAllServers(
        hiddenLibraryKeys: hiddenKeys,
        useGlobalHubs: settings.read(SettingsService.useGlobalHubs),
        includePlaybackHubs: false,
        serverIds: serverIds,
      );
      final fetchedOnDeck = await onDeckFuture;
      final fetchedHubs = await hubsFuture;
      if (isDisposed) return const {};
      final incomplete = {
        for (final MapEntry(:key, :value) in _watchStateClients(only: serverIds).entries)
          if (value.lastHomeReadIncomplete) key,
      };
      // A full or delta pass started meanwhile owns the rows now.
      if (revision != _contentRevision ||
          _onDeckState != DiscoverLoadState.loaded ||
          _hubsState != DiscoverLoadState.loaded) {
        return incomplete;
      }

      // Only a complete read replaces what is shown (Silo Android #1009): an
      // incomplete one may hold the offline cache's older rows or miss a row;
      // it is read again on the retry backoff.
      var onDeckChanged = false;
      var hubsChanged = false;
      final onDeckIds = fetchedOnDeck.succeededServerIds.difference(incomplete);
      if (onDeckIds.isNotEmpty) {
        final kept = _continueWatchingWithoutServers(onDeckIds);
        final merged = await aggregation.mergeContinueWatching(
          kept.items,
          [
            for (final item in fetchedOnDeck.items)
              if (onDeckIds.contains(item.serverId)) item,
          ],
          existingCopies: kept.copies,
          freshCopies: fetchedOnDeck.copies,
          limit: _continueWatchingProbeLimit,
        );
        if (isDisposed || revision != _contentRevision) return incomplete;
        // The kept rows are already trimmed to the preview, so rows of other
        // servers past it are unknown here: a "more" they gave stays.
        final hasMore =
            merged.items.length > continueWatchingPreviewLimit || (_hasMoreContinueWatching && kept.items.isNotEmpty);
        final items = merged.items.length > continueWatchingPreviewLimit
            ? merged.items.take(continueWatchingPreviewLimit).toList()
            : merged.items;
        if (!listEquals(items, _onDeck) ||
            hasMore != _hasMoreContinueWatching ||
            !_sameCopies(merged.copies, _continueWatchingCopies)) {
          _continueWatchingCopies = merged.copies;
          _replaceOnDeck(items, hasMore: hasMore);
          onDeckChanged = true;
        }
        _loadedOnDeckServerIds = {..._loadedOnDeckServerIds, ...onDeckIds};
      }

      final hubIds = fetchedHubs.succeededServerIds.difference(incomplete);
      if (hubIds.isNotEmpty) {
        final merged = _hubsReplacingServers(hubIds, [
          for (final hub in _filterDiscoverHubs(fetchedHubs.hubs))
            if (hubIds.contains(hub.serverId)) hub,
        ]);
        sortMediaHubsByLibraryOrder(merged, _libraries.libraries);
        if (!_sameHubs(merged, _hubs)) {
          _replaceHubs(merged);
          hubsChanged = true;
        }
        _loadedHubServerIds = {..._loadedHubServerIds, ...hubIds};
      }

      _recordObservations(
        observation,
        [
          for (final row in fetchedOnDeck.observedItems)
            if (onDeckIds.contains(row.item.serverId)) row,
          for (final row in fetchedHubs.observedItems)
            if (hubIds.contains(row.item.serverId)) row,
        ],
        {...onDeckIds, ...hubIds},
      );
      appLogger.d(
        'DiscoverProvider: Silo Home rows re-read '
        '(continue watching ${onDeckChanged ? 'updated' : 'unchanged'}, rows ${hubsChanged ? 'updated' : 'unchanged'}'
        '${incomplete.isEmpty ? '' : ', incomplete'})',
      );
      if (onDeckChanged || hubsChanged) safeNotifyListeners();
      if (onDeckChanged) unawaited(_syncSystemShelf(_onDeck));
      return incomplete;
    } catch (e) {
      if (!isDisposed) appLogger.w('DiscoverProvider: Silo Home rows not re-read', error: e);
      return const {};
    }
  }

  /// The Continue Watching rows and copy groups without anything from
  /// [serverIds]; a row from one of them whose group holds a copy from
  /// another server leaves that copy in its place.
  ({List<MediaItem> items, Map<String, List<MediaItem>> copies}) _continueWatchingWithoutServers(
    Set<String> serverIds,
  ) {
    final items = <MediaItem>[];
    final copies = <String, List<MediaItem>>{};
    for (final row in _onDeck) {
      final group = _continueWatchingCopies[row.globalKey] ?? [row];
      final kept = group.where((item) => !serverIds.contains(item.serverId)).toList();
      if (kept.isEmpty) continue;
      final shown = kept.any((item) => item.globalKey == row.globalKey) ? row : kept.first;
      items.add(shown);
      if (kept.length > 1) copies[shown.globalKey] = kept;
    }
    return (items: items, copies: copies);
  }

  /// [_hubs] with the Home rows of [serverIds] replaced by [fresh] where
  /// their first row was (appended for a server that had none). Their
  /// recommendation rows stay, less those the fresh rows now show.
  List<MediaHub> _hubsReplacingServers(Set<String> serverIds, List<MediaHub> fresh) {
    final freshByServer = <String, List<MediaHub>>{};
    for (final hub in fresh) {
      final serverId = hub.serverId;
      if (serverId != null) (freshByServer[serverId] ??= []).add(hub);
    }
    bool replaced(MediaHub hub) =>
        hub.serverId != null && serverIds.contains(hub.serverId) && !hub.personalRecommendations;
    final placed = <String>{};
    final merged = <MediaHub>[];
    for (final hub in _hubs) {
      if (!replaced(hub)) {
        merged.add(hub);
      } else if (placed.add(hub.serverId!)) {
        merged.addAll(freshByServer[hub.serverId!] ?? const []);
      }
    }
    for (final serverId in serverIds) {
      if (placed.add(serverId)) merged.addAll(freshByServer[serverId] ?? const []);
    }
    final recommendations = [
      for (final hub in merged)
        if (hub.personalRecommendations && serverIds.contains(hub.serverId)) hub,
    ];
    if (recommendations.isEmpty) return merged;
    final keptRecommendations = Set<MediaHub>.identity()
      ..addAll(withoutRecommendationsShownOnHome(recommendations, fresh).kept);
    return [
      for (final hub in merged)
        if (!hub.personalRecommendations || !serverIds.contains(hub.serverId) || keptRecommendations.contains(hub)) hub,
    ];
  }

  static bool _sameCopies(Map<String, List<MediaItem>> a, Map<String, List<MediaItem>> b) {
    if (a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      final other = b[key];
      if (other == null || !listEquals(value, other)) return false;
    }
    return true;
  }

  static bool _sameHubs(List<MediaHub> a, List<MediaHub> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (identical(x, y)) continue;
      if (x.id != y.id ||
          x.identifier != y.identifier ||
          x.title != y.title ||
          x.type != y.type ||
          x.size != y.size ||
          x.more != y.more ||
          x.libraryId != y.libraryId ||
          x.serverId != y.serverId ||
          x.serverName != y.serverName ||
          x.personalRecommendations != y.personalRecommendations ||
          !listEquals(x.items, y.items)) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _multiServer.removeOnlineServersListener(_onOnlineServersChanged);
    _stopWatchStateWatches();
    _watchStateDebounceTimer?.cancel();
    _watchStateRetryTimer?.cancel();
    _recommendationsSetting?.removeListener(_onRecommendationsSettingChanged);
    _hiddenLibraries.removeListener(_onHiddenLibrariesChanged);
    _libraries.removeListener(_onLibrariesChanged);
    _watchStateSubscription?.cancel();
    _watchStateSubscription = null;
    _deletionSubscription?.cancel();
    _deletionSubscription = null;
    _libraryEventSubscription?.cancel();
    _libraryEventSubscription = null;
    _shelfPublicationSubscription?.cancel();
    _shelfPublicationSubscription = null;
    _siloMembershipSubscription?.cancel();
    _siloMembershipSubscription = null;
    _libraryEventPacer.dispose();
    _loadCoordinator.dispose();
    _pendingSystemShelfItems = null;
    super.dispose();
  }
}
