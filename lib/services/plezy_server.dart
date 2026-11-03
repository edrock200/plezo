/// The one switch for the features that relied on services the Plezy project
/// runs or registered.
///
/// Plezilo is a fork of Plezy. Plezy's trademark policy (TRADEMARKS.md,
/// "Services") does not let a distributed fork use them: `ice.plezy.app` (the
/// tracker OAuth proxy, log uploads and Discord posters), `bugs.plezy.app`
/// (crash reports), Plezy's Discord application, and its Trakt, MyAnimeList,
/// AniList, Simkl and MDBList app registrations. Until Plezilo registers its
/// own apps and runs its own instance of `server/`, these features are off and
/// nothing in the app contacts those services:
///
/// * Trakt, MyAnimeList, AniList, Simkl and MDBList sync: hidden from Settings ›
///   Services, the settings summary and the rating sheet, and never started.
/// * Discord rich presence: reported unavailable, so it never connects.
/// * Log upload: the upload buttons are hidden (copying logs still works).
/// * Crash reports: never initialised, whatever `ENABLE_SENTRY` says, and the
///   setting is hidden.
///
/// To turn them back on: register Plezilo's own apps, point [plezyServerBaseUrl]
/// and the tracker client ids at them, set a Sentry DSN in `lib/main.dart`, and
/// flip this to true.
const bool plezyProjectServicesEnabled = false;

/// Base URL of the server behind the tracker OAuth proxy (`/auth`), log
/// uploads (`/logs`) and Discord posters (`/posters`). Empty while
/// [plezyProjectServicesEnabled] is off: Plezy's own host must not be used.
/// Watch Together rooms run on Open Watch Party relays, not here.
const String plezyServerBaseUrl = '';
