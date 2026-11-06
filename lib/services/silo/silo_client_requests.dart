part of 'silo_client.dart';

final Expando<SiloRequestsApi> _siloRequests = Expando('SiloRequestsApi');
final Expando<SiloCalendarApi> _siloCalendar = Expando('SiloCalendarApi');

/// Silo's media requests and calendar for this client's account and profile
/// (`silo_requests.dart`, `silo_calendar.dart`). Kept out of [SiloClient]'s
/// body: each client gets its own instances on first use, so a profile or
/// server switch (a new client) starts with the requests gate closed.
extension SiloClientRequestsCalendar on SiloClient {
  SiloRequestsApi get requests => _siloRequests[this] ??= SiloRequestsApi(_api, isOffline: () => isOfflineMode);

  SiloCalendarApi get calendar => _siloCalendar[this] ??= SiloCalendarApi(_api);
}
