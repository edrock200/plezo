import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/silo/silo_client.dart';
import '../../widgets/app_menu.dart';
import 'silo_calendar_screen.dart';
import 'silo_requests_screen.dart';

/// Entry points for Silo's own pages (Calendar, Requests) in Plezilo's
/// profile menu: present only while a Silo server is online, and Requests
/// only while that server's `GET /api/v2/requests/status` enables requests
/// for the profile (Silo Android #782: Requests is a profile-menu row on TV).

/// The online Silo clients of the visible servers, in server order.
List<SiloClient> onlineSiloClients(MultiServerProvider? servers) => [
  if (servers != null)
    for (final id in servers.onlineServerIds)
      if (servers.getClientForServer(ServerId(id)) case final SiloClient client) client,
];

/// Ask each online Silo server whether requests are on (at most one read in
/// flight per client, skipped while the last answer is fresh), so the menu
/// knows when it opens.
void warmSiloFeatureEntries(MultiServerProvider? servers) {
  for (final client in onlineSiloClients(servers)) {
    unawaited(client.requests.refreshStatus());
  }
}

const _calendarPrefix = 'silo_calendar:';
const _requestsPrefix = 'silo_requests:';

/// The menu rows: one Calendar row per online Silo server, one Requests row
/// per server that enables requests. A row names its server only when more
/// than one Silo server is online.
List<AppMenuEntry<String>> siloFeatureMenuEntries(MultiServerProvider? servers) {
  final clients = onlineSiloClients(servers);
  if (clients.isEmpty) return const [];
  final named = clients.length > 1;
  String server(SiloClient c) => c.serverName ?? c.serverId.value;
  return [
    for (final client in clients)
      AppMenuItem<String>(
        value: '$_calendarPrefix${client.serverId.value}',
        icon: Symbols.calendar_month_rounded,
        label: named ? t.siloCalendar.menuEntryOnServer(server: server(client)) : t.siloCalendar.menuEntry,
      ),
    for (final client in clients)
      if (client.requests.enabled.value)
        AppMenuItem<String>(
          value: '$_requestsPrefix${client.serverId.value}',
          icon: Symbols.playlist_add_rounded,
          label: named ? t.siloRequests.menuEntryOnServer(server: server(client)) : t.siloRequests.menuEntry,
        ),
  ];
}

/// Opens the page a [siloFeatureMenuEntries] row names; false for any other
/// menu value.
bool handleSiloFeatureMenuValue(BuildContext context, MultiServerProvider? servers, String value) {
  final isCalendar = value.startsWith(_calendarPrefix);
  if (!isCalendar && !value.startsWith(_requestsPrefix)) return false;
  final serverId = value.substring((isCalendar ? _calendarPrefix : _requestsPrefix).length);
  final client = servers?.getClientForServer(ServerId(serverId));
  if (client is! SiloClient) return true;
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => isCalendar ? SiloCalendarScreen(client: client) : SiloRequestsScreen(client: client),
      ),
    ),
  );
  return true;
}
