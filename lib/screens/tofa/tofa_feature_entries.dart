import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/tofa/tofa_client.dart';
import '../../widgets/app_menu.dart';
import 'tofa_discover_screen.dart';
import 'tofa_history_screen.dart';
import 'tofa_profile_switch_screen.dart';
import 'tofa_requests_screen.dart';

/// Entry points for Tofa's own pages in Plezilo's profile menu, as Silo's
/// Calendar and Requests are (`silo_feature_entries.dart`): Discover,
/// Requests, History and Switch Tofa profile, one row each per online Tofa
/// server. Discover and Requests show once `GET /system/info` says
/// `discover_enabled` / `requests_available` is on (an unknown answer shows
/// Discover, whose page explains itself).

List<TofaClient> onlineTofaClients(MultiServerProvider? servers) => [
  if (servers != null)
    for (final id in servers.onlineServerIds)
      if (servers.getClientForServer(ServerId(id)) case final TofaClient client) client,
];

final Map<String, ({bool? requests, bool? discover})> _features = {};

/// Read each online Tofa server's features, so the menu knows when it opens.
void warmTofaFeatureEntries(MultiServerProvider? servers) {
  for (final client in onlineTofaClients(servers)) {
    unawaited(client.serverFeatures().then((f) => _features[client.serverId.value] = f));
  }
}

const _discoverPrefix = 'tofa_discover:';
const _requestsPrefix = 'tofa_requests:';
const _historyPrefix = 'tofa_history:';
const _profilePrefix = 'tofa_profile:';

List<AppMenuEntry<String>> tofaFeatureMenuEntries(MultiServerProvider? servers) {
  final clients = onlineTofaClients(servers);
  if (clients.isEmpty) return const [];
  final named = clients.length > 1;
  String server(TofaClient c) => c.serverName ?? c.serverId.value;
  String label(String plain, TofaClient c) => named ? t.tofaExtras.onServer(label: plain, server: server(c)) : plain;
  return [
    for (final client in clients) ...[
      if (_features[client.serverId.value]?.discover != false)
        AppMenuItem<String>(
          value: '$_discoverPrefix${client.serverId.value}',
          icon: Symbols.explore_rounded,
          label: label(t.tofaExtras.discover, client),
        ),
      if (_features[client.serverId.value]?.requests == true)
        AppMenuItem<String>(
          value: '$_requestsPrefix${client.serverId.value}',
          icon: Symbols.playlist_add_rounded,
          label: label(t.tofaExtras.requests, client),
        ),
      AppMenuItem<String>(
        value: '$_historyPrefix${client.serverId.value}',
        icon: Symbols.history_rounded,
        label: label(t.tofaExtras.history, client),
      ),
      AppMenuItem<String>(
        value: '$_profilePrefix${client.serverId.value}',
        icon: Symbols.switch_account_rounded,
        label: label(t.tofaExtras.switchProfile, client),
      ),
    ],
  ];
}

/// Opens the page a [tofaFeatureMenuEntries] row names; false for any other
/// menu value.
bool handleTofaFeatureMenuValue(BuildContext context, MultiServerProvider? servers, String value) {
  Widget Function(TofaClient)? build;
  String? prefix;
  for (final (p, b) in <(String, Widget Function(TofaClient))>[
    (_discoverPrefix, (c) => TofaDiscoverScreen(client: c)),
    (_requestsPrefix, (c) => TofaRequestsScreen(client: c)),
    (_historyPrefix, (c) => TofaHistoryScreen(client: c)),
    (_profilePrefix, (c) => TofaProfileSwitchScreen(client: c)),
  ]) {
    if (value.startsWith(p)) {
      prefix = p;
      build = b;
    }
  }
  if (prefix == null || build == null) return false;
  final client = servers?.getClientForServer(ServerId(value.substring(prefix.length)));
  if (client is! TofaClient) return true;
  final screen = build(client);
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)));
  return true;
}
