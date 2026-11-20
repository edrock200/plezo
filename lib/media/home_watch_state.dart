/// Home's watch state for servers whose Home rows can be re-read on their own
/// (Silo): Continue Watching, watched checks and progress change when a title
/// is played or marked on another device, and Silo's apps re-read Home when it
/// is shown again, when the app returns and when the server's event stream
/// says the profile's watch state changed (Silo Android #1009, Silo's Roku app
/// #102).
library;

/// Why a watch-state signal arrived from a server's event stream.
enum HomeWatchStateSignal {
  /// The profile's watch state changed (`user_state.changed`) or its access
  /// changed (`access_changed`): Home's rows may be out of date.
  changed,

  /// The stream subscribed again after a disconnect: changes made meanwhile
  /// were not delivered, so Home catches up with one read.
  reconnected,

  /// The stream is unavailable (an older server, or it keeps failing): a
  /// periodic check stands in for it.
  poll,
}

/// A running watch on a server's watch-state events. [stop] ends it for good.
abstract interface class HomeWatchStateWatch {
  void stop();
}

/// A client that can re-read its Home rows alone and report watch-state
/// changes made elsewhere. Implemented by `SiloClient` only; Plex, Jellyfin
/// and Emby keep their own refresh rules.
abstract interface class HomeWatchStateClient {
  /// Whether the newest Home read left rows out, or kept the rows already
  /// shown, because of a transient failure (timeout, 408, 429, 5xx, a lost
  /// connection, or an answer served from the offline cache). Home reads
  /// again with a short backoff when it is.
  bool get lastHomeReadIncomplete;

  /// Starts listening to the server's watch-state events for this
  /// connection's profile, or returns null when the client cannot (closed,
  /// offline, signed out). The watch reconnects on its own until stopped.
  HomeWatchStateWatch? watchHomeWatchState(void Function(HomeWatchStateSignal signal) onSignal);
}
