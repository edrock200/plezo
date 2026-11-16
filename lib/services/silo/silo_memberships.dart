import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../../utils/error_message_utils.dart';
import 'silo_api.dart';
import 'silo_personal_lists.dart';

/// A Silo personal list a title can be on: the Watchlist or Favorites
/// (`user_state.in_watchlist` / `is_favorite`; `PUT`/`DELETE`
/// `/api/v2/watchlist/{content_id}` and `/api/v2/favorites/{content_id}`).
enum SiloMembership {
  watchlist('in_watchlist', 'watchlist', 'watchlist', SiloPersonalList.watchlist),
  favorite('is_favorite', 'favorites', 'favorites', SiloPersonalList.favorites);

  const SiloMembership(this.userStateField, this.pathSegment, this.sectionType, this.list);

  /// The `user_state` field that says whether the title is on the list.
  final String userStateField;

  /// `/api/v2/<pathSegment>/{content_id}`.
  final String pathSegment;

  /// The Home `section_type` of the row that shows the list.
  final String sectionType;

  /// The For You page's list for it.
  final SiloPersonalList list;
}

/// A confirmed membership change, for pages that show the lists.
class SiloMembershipChange {
  const SiloMembershipChange({required this.serverId, required this.kind, required this.itemId, required this.value});

  final String serverId;
  final SiloMembership kind;
  final String itemId;
  final bool value;
}

/// What a press ended in, once the server answered. Null from
/// [SiloMembershipStore.toggle] means the press was queued behind a write in
/// flight; the write that sends it reports.
class SiloMembershipOutcome {
  const SiloMembershipOutcome({required this.kind, required this.value, this.error});

  final SiloMembership kind;

  /// The state that was asked for.
  final bool value;

  /// The refusal, or null when the server took it.
  final Object? error;

  bool get ok => error == null;

  /// "Added to Watchlist", or "Couldn't add to Watchlist." with the reason.
  String get message {
    final m = t.siloMemberships;
    if (ok) {
      return switch ((kind, value)) {
        (SiloMembership.watchlist, true) => t.explore.addedToWatchlist,
        (SiloMembership.watchlist, false) => t.explore.removedFromWatchlist,
        (SiloMembership.favorite, true) => m.addedToFavorites,
        (SiloMembership.favorite, false) => m.removedFromFavorites,
      };
    }
    final reason = siloMembershipFailureReason(error!);
    return switch ((kind, value)) {
      (SiloMembership.watchlist, true) => m.addToWatchlistFailed(reason: reason),
      (SiloMembership.watchlist, false) => m.removeFromWatchlistFailed(reason: reason),
      (SiloMembership.favorite, true) => m.addToFavoritesFailed(reason: reason),
      (SiloMembership.favorite, false) => m.removeFromFavoritesFailed(reason: reason),
    };
  }
}

/// The server's own reason for a refused write (its problem `detail`), else a
/// plain reason for timeouts and unreachable servers, else "Try again."
String siloMembershipFailureReason(Object error) {
  if (error is MediaServerHttpException) {
    final detail = siloProblemDetail(error.responseData);
    if (detail != null) return detail;
  }
  final reason = localizedErrorReason(error);
  return reason == t.errors.reasonUnexpected ? t.siloMemberships.tryAgain : reason;
}

class _Write {
  _Write(this.confirmed);

  /// What the server last confirmed.
  bool confirmed;
  bool inFlight = false;
  bool? pending;
}

/// Watchlist and Favorites state for one Silo connection (Siku's
/// `toggleMembership`, Silo Android `PersonalDataRepository.memberships`).
///
/// A press changes the state at once; one write per title and list is in
/// flight at a time, and a press meanwhile is sent when it answers (the
/// latest press wins), so quick presses never reach the server out of order.
/// A refused write puts the state back to what the server last confirmed.
/// The state the user set this session overrides what cards and pages carry
/// (their `user_state` was read before the change).
class SiloMembershipStore extends ChangeNotifier {
  SiloMembershipStore({required this.serverId, required Future<void> Function(MediaItem, SiloMembership, bool) write})
    : _send = write;

  final String serverId;
  final Future<void> Function(MediaItem item, SiloMembership kind, bool value) _send;
  final Map<(String, SiloMembership), bool> _overrides = {};
  final Map<(String, SiloMembership), _Write> _writes = {};

  static final StreamController<SiloMembershipChange> _changes = StreamController.broadcast();

  /// Every change a server took, from any Silo connection.
  static Stream<SiloMembershipChange> get changes => _changes.stream;

  /// Whether [item] is on [kind]'s list, as far as this session knows.
  bool isMember(MediaItem item, SiloMembership kind) => _overrides[(item.id, kind)] ?? fromItem(item, kind);

  /// What the item itself carries (`user_state` of the JSON it came from).
  static bool fromItem(MediaItem item, SiloMembership kind) {
    if (kind == SiloMembership.favorite && item.isFavorite == true) return true;
    final userState = item.raw?['user_state'];
    return userState is Map && userState[kind.userStateField] == true;
  }

  /// Flips [kind] for [item]. Completes with the outcome once the server
  /// answered, or with null when the press was queued behind a write.
  Future<SiloMembershipOutcome?> toggle(MediaItem item, SiloMembership kind) async {
    final key = (item.id, kind);
    final current = isMember(item, kind);
    final desired = !current;
    final write = _writes[key] ??= _Write(current);
    _overrides[key] = desired;
    notifyListeners();
    if (write.inFlight) {
      write.pending = desired;
      return null;
    }
    var value = desired;
    while (true) {
      write.inFlight = true;
      write.pending = null;
      try {
        await _send(item, kind, value);
      } catch (e) {
        write.inFlight = false;
        write.pending = null;
        appLogger.i('Silo: ${kind.name} write failed (${e.runtimeType})');
        _overrides[key] = write.confirmed;
        notifyListeners();
        return SiloMembershipOutcome(kind: kind, value: value, error: e);
      }
      write.inFlight = false;
      write.confirmed = value;
      _changes.add(SiloMembershipChange(serverId: serverId, kind: kind, itemId: item.id, value: value));
      final pending = write.pending;
      if (pending != null && pending != value) {
        value = pending;
        continue;
      }
      write.pending = null;
      return SiloMembershipOutcome(kind: kind, value: value);
    }
  }

  @visibleForTesting
  bool? debugOverride(String itemId, SiloMembership kind) => _overrides[(itemId, kind)];
}
