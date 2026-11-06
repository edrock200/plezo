import 'package:flutter/material.dart';
import '../media/ids.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../profiles/active_profile_provider.dart';
import '../providers/multi_server_provider.dart';
import '../screens/settings/add_connection_screen.dart';
import '../screens/settings/add_silo_screen.dart';
import '../services/silo/silo_client.dart';
import '../focus/focusable_button.dart';
import 'app_icon.dart';

/// Top-of-app banner for servers that answered and refused this account.
/// Distinct from "server offline" — the server is reachable, so empty hubs
/// need an explanation.
///
/// Two refusals, two rows. A rejected token (HTTP 401,
/// [MultiServerProvider.authErrorServers]) gets a CTA: one Silo server opens
/// "Sign in again" on its connection ([AddSiloScreen.editConnection]);
/// anything else opens [AddConnectionScreen]; the user picks the right backend and the resulting
/// token replaces the stale row in the registry, which clears the auth-error
/// state on the next health sweep. A refused account (HTTP 403,
/// [MultiServerProvider.accessDeniedServers]) gets no CTA: a new sign-in gets
/// the same refusal, and only the server owner or the network the device is on
/// can change it.
///
/// Collapses to `SizedBox.shrink()` when no visible server refuses.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final signInEntries = context.select<MultiServerProvider, List<({ServerId serverId, String displayName})>>(
      (p) => p.authErrorServers,
    );
    final deniedEntries = context.select<MultiServerProvider, List<({ServerId serverId, String displayName})>>(
      (p) => p.accessDeniedServers,
    );
    if (signInEntries.isEmpty && deniedEntries.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (signInEntries.isNotEmpty)
              _BannerRow(
                icon: Symbols.lock_rounded,
                label: signInEntries.length == 1
                    ? t.connections.sessionExpiredOne(name: signInEntries.first.displayName)
                    : t.connections.sessionExpiredMany(count: signInEntries.length),
                action: FocusableButton(
                  onPressed: () => _openReauth(context, signInEntries),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.onErrorContainer,
                      foregroundColor: scheme.errorContainer,
                    ),
                    onPressed: () => _openReauth(context, signInEntries),
                    child: Text(t.connections.signInAgain),
                  ),
                ),
              ),
            if (deniedEntries.isNotEmpty)
              _BannerRow(
                icon: Symbols.block_rounded,
                label: deniedEntries.length == 1
                    ? t.connections.accessDeniedOne(name: deniedEntries.first.displayName)
                    : t.connections.accessDeniedMany(count: deniedEntries.length),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReauth(BuildContext context, List<({ServerId serverId, String displayName})> entries) async {
    // One Silo server: "Sign in again" on its own connection, which keeps the
    // connection id, its profiles and its downloads (Silo's apps do the same).
    final silo = entries.length == 1
        ? context.read<MultiServerProvider>().serverManager.getClient(entries.single.serverId)
        : null;
    if (silo is SiloClient) {
      final target = context.read<ActiveProfileProvider>().active;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AddSiloScreen(editConnection: silo.connection, targetProfile: target, signInAgain: true),
        ),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddConnectionScreen()));
  }
}

class _BannerRow extends StatelessWidget {
  const _BannerRow({required this.icon, required this.label, this.action});

  final IconData icon;
  final String label;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final action = this.action;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, action == null ? 16 : 8, 8),
      child: Row(
        children: [
          AppIcon(icon, fill: 1, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer, fontWeight: .w500),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action],
        ],
      ),
    );
  }
}
