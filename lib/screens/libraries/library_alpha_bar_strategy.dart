import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../media/library_first_character.dart';
import '../../media/library_query.dart';
import '../../media/media_backend.dart';
import '../../services/plex_client.dart';
import '../../services/silo/silo_letter_index.dart';
import 'alpha_jump_helper.dart';

/// Backend-specific alpha-jump-bar behaviour.
///
/// Plex libraries use real per-letter counts from
/// `/library/sections/{id}/firstCharacter`, so the bar is scroll-position
/// driven — tapping a letter scrolls to that letter's cumulative offset and
/// the highlighted letter follows the visible row.
///
/// MediaBrowser libraries have no per-letter count endpoint. The bar
/// synthesises the 27-letter alphabet (`#`, `A`–`Z`) and acts as a name-prefix
/// filter that refetches the page when the user picks a letter (matching the
/// server web clients' UX).
abstract class LibraryAlphaBarStrategy {
  /// Whether the bar should be rendered at all. Implementations consider
  /// total item count, sort key, and current filter state.
  bool shouldShow({
    required int totalItemCount,
    required int loadedCharacterCount,
    required String? sortKey,
    required bool isFolderGrouping,
    required String? mediaBrowserAlphaPrefix,
    required bool isPhone,
  });

  /// Load the first-character buckets for the current filter state.
  /// Returns the new helper plus the synthesised character list — the caller
  /// stores both in widget state.
  Future<({List<LibraryFirstCharacter> chars, AlphaJumpHelper helper})> loadCharacters({
    required Map<String, dynamic> filters,
    required int? typeId,
    required bool descending,
  });

  /// Letter to highlight given the current scroll-derived index. Plex maps
  /// the index back through the cumulative offsets; MediaBrowser backends echo
  /// back whatever filter is active.
  String currentLetter(int index, AlphaJumpHelper helper, {String? mediaBrowserAlphaPrefix});

  /// Handle a tap on the letter at [targetIndex]. Plex strategies invoke
  /// [onPlexJump] with the cumulative item index for in-grid scrolling;
  /// MediaBrowser strategies invoke [onMediaBrowserPrefixChange] with the next
  /// `NameStartsWith` prefix (or `null` to clear the filter when the user
  /// re-taps the active letter). Each strategy ignores the callback that
  /// doesn't apply to its UX, so callers can wire both unconditionally.
  void onLetterPressed(
    int targetIndex,
    AlphaJumpHelper helper, {
    required String? currentMediaBrowserPrefix,
    required void Function(int index) onPlexJump,
    required void Function(String? nextPrefix) onMediaBrowserPrefixChange,
  });

  /// Construct the right strategy for [backend].
  ///
  /// Silo uses [SiloAlphaBarStrategy] when [siloQuery] and [siloLetterIndex]
  /// are given, and the static `name_prefix` bar otherwise.
  factory LibraryAlphaBarStrategy.forBackend(
    MediaBackend backend, {
    required PlexClient Function() plexClientProvider,
    required String libraryKey,
    required bool isShared,
    LibraryQuery Function()? siloQuery,
    SiloLetterIndexLoader? siloLetterIndex,
  }) {
    return switch (backend) {
      MediaBackend.plex => PlexAlphaBarStrategy(
        plexClientProvider: plexClientProvider,
        libraryKey: libraryKey,
        isShared: isShared,
      ),
      MediaBackend.silo when siloQuery != null && siloLetterIndex != null => SiloAlphaBarStrategy(
        currentQuery: siloQuery,
        loadLetterIndex: siloLetterIndex,
      ),
      MediaBackend.jellyfin || MediaBackend.emby || MediaBackend.silo => const MediaBrowserAlphaBarStrategy(),
    };
  }
}

/// Reads Silo's letter index for [query] (`SiloClient.fetchLetterIndex`):
/// null when the server has none.
typedef SiloLetterIndexLoader = Future<SiloLetterIndex?> Function(LibraryQuery query);

/// Silo strategy (Silo Android #888) — on a server with the letter index
/// (`POST /api/v2/catalog/letters`) the bar behaves like Plex's: real
/// per-letter counts, shown in title order only (on phones too), and a tap
/// scrolls the grid to the letter's first title, whose list position comes
/// from the index rather than from cumulative counts (the server's collation
/// can sort part of a letter after Z). The grid reads far positions with
/// `seek` + `window_cursor` (`SiloClient` paging).
///
/// A server without the index (404/405/501) keeps the static A–Z
/// `name_prefix` filter of [MediaBrowserAlphaBarStrategy].
class SiloAlphaBarStrategy implements LibraryAlphaBarStrategy {
  /// The grid's current query (filters, sort, kind) — read at each load.
  final LibraryQuery Function() currentQuery;
  final SiloLetterIndexLoader loadLetterIndex;

  SiloAlphaBarStrategy({required this.currentQuery, required this.loadLetterIndex});

  static const _prefixBar = MediaBrowserAlphaBarStrategy();

  /// The index of the list the grid shows; null outside title order, before
  /// it arrives and on a server without one.
  SiloLetterIndex? _index;

  /// Null until the server first answers; false keeps the prefix bar.
  bool? _serverHasIndex;

  /// Bumps with every load; only the newest load's answer is kept.
  int _generation = 0;

  /// Whether the bar filters with `name_prefix` (no letter index).
  bool get filtersByPrefix => _serverHasIndex == false;

  /// The letter index in use, for tests.
  @visibleForTesting
  SiloLetterIndex? get letterIndex => _index;

  /// Whether [query] lists titles in title order (Silo's default sort).
  static bool sortsByTitle(LibraryQuery query) {
    final field = query.sort?.field;
    if (field == null || field.isEmpty) return true;
    final bare = field.endsWith(':desc') ? field.substring(0, field.length - 5) : field;
    return bare == 'title' || bare == 'titleSort';
  }

  @override
  bool shouldShow({
    required int totalItemCount,
    required int loadedCharacterCount,
    required String? sortKey,
    required bool isFolderGrouping,
    required String? mediaBrowserAlphaPrefix,
    required bool isPhone,
  }) {
    if (filtersByPrefix) {
      return _prefixBar.shouldShow(
        totalItemCount: totalItemCount,
        loadedCharacterCount: loadedCharacterCount,
        sortKey: sortKey,
        isFolderGrouping: isFolderGrouping,
        mediaBrowserAlphaPrefix: mediaBrowserAlphaPrefix,
        isPhone: isPhone,
      );
    }
    if (isFolderGrouping || _index == null) return false;
    if (loadedCharacterCount < 6 || totalItemCount < 80) return false;
    final s = sortKey ?? '';
    return s.isEmpty || s == 'title' || s.startsWith('titleSort');
  }

  @override
  Future<({List<LibraryFirstCharacter> chars, AlphaJumpHelper helper})> loadCharacters({
    required Map<String, dynamic> filters,
    required int? typeId,
    required bool descending,
  }) async {
    final generation = ++_generation;
    if (_serverHasIndex == false) {
      _index = null;
      return _prefixBar.loadCharacters(filters: filters, typeId: typeId, descending: descending);
    }
    final query = currentQuery();
    final titleOrder = sortsByTitle(query);
    if (!titleOrder && _serverHasIndex == true) {
      _index = null;
      return _noBar();
    }
    final SiloLetterIndex? index;
    try {
      // Outside title order this only learns whether the server has an index.
      index = await loadLetterIndex(query);
    } catch (_) {
      if (generation == _generation) _index = null;
      rethrow;
    }
    // A newer load owns the bar; its caller drops this answer too.
    if (generation != _generation) return _noBar();
    if (index == null) {
      _serverHasIndex = false;
      _index = null;
      return _prefixBar.loadCharacters(filters: filters, typeId: typeId, descending: descending);
    }
    _serverHasIndex = true;
    if (!titleOrder || index.total <= 0) {
      _index = null;
      return _noBar();
    }
    _index = index;
    final chars = [for (final l in index.letters) LibraryFirstCharacter(key: l.letter, title: l.letter, size: l.count)];
    return (chars: chars, helper: AlphaJumpHelper(chars, descending: descending));
  }

  static ({List<LibraryFirstCharacter> chars, AlphaJumpHelper helper}) _noBar() =>
      (chars: const <LibraryFirstCharacter>[], helper: AlphaJumpHelper(const []));

  @override
  String currentLetter(int index, AlphaJumpHelper helper, {String? mediaBrowserAlphaPrefix}) {
    if (filtersByPrefix) return mediaBrowserAlphaPrefix ?? '';
    return _index?.letterAt(index) ?? helper.currentLetter(index);
  }

  /// The bar reports the letter's cumulative offset in its own (count
  /// ordered) list; map it back to the letter and jump to that letter's
  /// position in the server's list.
  @override
  void onLetterPressed(
    int targetIndex,
    AlphaJumpHelper helper, {
    required String? currentMediaBrowserPrefix,
    required void Function(int index) onPlexJump,
    required void Function(String? nextPrefix) onMediaBrowserPrefixChange,
  }) {
    if (filtersByPrefix) {
      _prefixBar.onLetterPressed(
        targetIndex,
        helper,
        currentMediaBrowserPrefix: currentMediaBrowserPrefix,
        onPlexJump: onPlexJump,
        onMediaBrowserPrefixChange: onMediaBrowserPrefixChange,
      );
      return;
    }
    final index = _index;
    if (index == null || helper.letters.isEmpty) return;
    final position = index.positionOf(helper.currentLetter(targetIndex));
    if (position != null) onPlexJump(position);
  }
}

/// Plex strategy — calls `/library/sections/{id}/firstCharacter` for real
/// per-letter counts and uses the cumulative offsets to drive scroll
/// position.
class PlexAlphaBarStrategy implements LibraryAlphaBarStrategy {
  final PlexClient Function() plexClientProvider;
  final String libraryKey;
  final bool isShared;

  PlexAlphaBarStrategy({required this.plexClientProvider, required this.libraryKey, required this.isShared});

  @override
  bool shouldShow({
    required int totalItemCount,
    required int loadedCharacterCount,
    required String? sortKey,
    required bool isFolderGrouping,
    required String? mediaBrowserAlphaPrefix,
    required bool isPhone,
  }) {
    if (isFolderGrouping) return false;
    if (loadedCharacterCount < 6 || totalItemCount < 80) return false;
    final s = sortKey ?? '';
    return s.isEmpty || s.startsWith('titleSort');
  }

  @override
  Future<({List<LibraryFirstCharacter> chars, AlphaJumpHelper helper})> loadCharacters({
    required Map<String, dynamic> filters,
    required int? typeId,
    required bool descending,
  }) async {
    if (isShared) {
      // Shared libraries don't support first-characters.
      return (chars: const <LibraryFirstCharacter>[], helper: AlphaJumpHelper(const []));
    }
    final client = plexClientProvider();
    final params = Map<String, dynamic>.from(filters);
    params['includeCollections'] = '1';
    final chars = await client.getFirstCharacters(libraryKey, type: typeId, filters: params.isNotEmpty ? params : null);
    return (chars: chars, helper: AlphaJumpHelper(chars, descending: descending));
  }

  @override
  String currentLetter(int index, AlphaJumpHelper helper, {String? mediaBrowserAlphaPrefix}) =>
      helper.currentLetter(index);

  /// Plex jumps the grid to the cumulative offset for the tapped letter —
  /// the helper's letter list already encodes the per-letter ranges from
  /// the server's `/firstCharacter` counts.
  @override
  void onLetterPressed(
    int targetIndex,
    AlphaJumpHelper helper, {
    required String? currentMediaBrowserPrefix,
    required void Function(int index) onPlexJump,
    required void Function(String? nextPrefix) onMediaBrowserPrefixChange,
  }) {
    onPlexJump(targetIndex);
  }
}

/// MediaBrowser strategy — synthesises the 27-letter alphabet locally and
/// uses the bar as a `NameStartsWith` filter.
class MediaBrowserAlphaBarStrategy implements LibraryAlphaBarStrategy {
  static const _letters = [
    '#',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];

  const MediaBrowserAlphaBarStrategy();

  @override
  bool shouldShow({
    required int totalItemCount,
    required int loadedCharacterCount,
    required String? sortKey,
    required bool isFolderGrouping,
    required String? mediaBrowserAlphaPrefix,
    required bool isPhone,
  }) {
    if (isPhone) return false;
    if (isFolderGrouping) return false;
    if (loadedCharacterCount == 0) return false;
    return totalItemCount >= 80 || mediaBrowserAlphaPrefix != null;
  }

  @override
  Future<({List<LibraryFirstCharacter> chars, AlphaJumpHelper helper})> loadCharacters({
    required Map<String, dynamic> filters,
    required int? typeId,
    required bool descending,
  }) async {
    final synthetic = [for (final l in _letters) LibraryFirstCharacter(key: l, title: l, size: 1)];
    return (chars: synthetic, helper: AlphaJumpHelper(synthetic, descending: descending));
  }

  @override
  String currentLetter(int index, AlphaJumpHelper helper, {String? mediaBrowserAlphaPrefix}) =>
      mediaBrowserAlphaPrefix ?? '';

  /// MediaBrowser backends reuse the alpha bar as a `NameStartsWith` filter.
  /// We map the bar offset back to a letter (the synthesised `size: 1` entries
  /// make offset == position in [helper.letters]) and toggle the filter —
  /// re-tap the active letter to clear, otherwise set the new prefix.
  @override
  void onLetterPressed(
    int targetIndex,
    AlphaJumpHelper helper, {
    required String? currentMediaBrowserPrefix,
    required void Function(int index) onPlexJump,
    required void Function(String? nextPrefix) onMediaBrowserPrefixChange,
  }) {
    if (targetIndex < 0 || targetIndex >= helper.letters.length) return;
    final letter = helper.letters[targetIndex];
    final next = (currentMediaBrowserPrefix == letter) ? null : letter;
    onMediaBrowserPrefixChange(next);
  }
}
