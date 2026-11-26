import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile_connection.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../services/tofa/tofa_auth_service.dart';
import '../../services/tofa/tofa_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../libraries/state_messages.dart';
import '../profile/pin_entry_dialog.dart';
import '../settings/connection_persistence.dart';

/// Switch a Tofa sign-in to another profile of the same account without
/// signing in again: `GET /profiles` with the saved tokens, the profile's PIN
/// through `POST /profiles/{id}/verify-pin` when it is locked, then the
/// active Plezilo profile uses that Tofa profile on this server (a connection
/// of its own, `server/user/profile`, as a fresh sign-in would save).
class TofaProfileSwitchScreen extends StatefulWidget {
  const TofaProfileSwitchScreen({super.key, required this.client});

  final TofaClient client;

  @override
  State<TofaProfileSwitchScreen> createState() => _TofaProfileSwitchScreenState();
}

class _TofaProfileSwitchScreenState extends State<TofaProfileSwitchScreen> {
  List<TofaProfile>? _profiles;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final profiles = await widget.client.accountProfiles();
      if (mounted) setState(() => _profiles = profiles);
    } catch (e) {
      appLogger.d('[tofa] profiles failed', error: e.runtimeType);
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _pick(TofaProfile profile) async {
    if (_busy || profile.id == widget.client.connection.profileId) return;
    TofaPinAccepted? pin;
    if (profile.isLocked) {
      String? error;
      while (pin == null) {
        final entered = await showPinEntryDialog(context, profile.name, errorMessage: error);
        if (entered == null || !mounted) return;
        setState(() => _busy = true);
        TofaPinResult? result;
        try {
          result = await widget.client.verifyProfilePin(profile, entered);
        } catch (e) {
          appLogger.d('[tofa] PIN check failed', error: e.runtimeType);
        }
        if (!mounted) return;
        setState(() => _busy = false);
        switch (result) {
          case final TofaPinAccepted accepted:
            pin = accepted;
          case TofaPinWrong():
            error = t.addServer.tofaWrongPin;
          case TofaPinTooManyTries():
            error = t.addServer.tofaTooManyPinAttempts;
          case null:
            error = t.addServer.tofaPinNetworkError;
        }
      }
    }
    if (!mounted) return;
    await _switchTo(profile, pin);
  }

  Future<void> _switchTo(TofaProfile profile, TofaPinAccepted? pin) async {
    final active = context.read<ActiveProfileProvider>();
    final joins = context.read<ProfileConnectionRegistry>();
    final binder = context.read<ActiveProfileBinder>();
    final plezoProfileId = active.activeId;
    if (plezoProfileId == null) {
      showErrorSnackBar(context, t.messages.noProfilesAvailable);
      return;
    }
    final old = widget.client.connection;
    final next = widget.client.connectionForProfile(profile, pin: pin);
    setState(() => _busy = true);
    try {
      final previous = await joins.get(plezoProfileId, old.id);
      if (!mounted) return;
      await persistAndBindConnection(
        context: context,
        connection: next,
        bindToProfile: ProfileConnection(
          profileId: plezoProfileId,
          connectionId: next.id,
          userToken: null,
          userIdentifier: next.userId,
          tokenAcquiredAt: DateTime.now(),
        ),
      );
      // The Plezilo profile now uses the new Tofa profile on this server,
      // not both (one active client per server).
      if (previous != null && old.id != next.id) {
        if (previous.isDefault) await joins.setDefault(plezoProfileId, next.id);
        await joins.remove(plezoProfileId, old.id);
      }
      await binder.rebindIfActive(plezoProfileId);
      appLogger.i('[tofa] switched to another profile of the account');
      if (!mounted) return;
      showSuccessSnackBar(context, t.tofaExtras.profileSwitched(name: profile.name));
      Navigator.of(context).pop(true);
    } catch (e) {
      appLogger.e('[tofa] profile switch failed', error: e);
      if (mounted) showErrorSnackBar(context, t.tofaExtras.actionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _profiles;
    final current = widget.client.connection.profileId;
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.tofaExtras.switchProfile),
      slivers: [
        if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorStateWidget(
              message: t.tofaExtras.loadFailed,
              icon: Symbols.error_outline_rounded,
              onRetry: _load,
            ),
          )
        else if (profiles == null)
          LoadingIndicatorBox.sliver
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                for (var i = 0; i < profiles.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: FocusableWrapper(
                      autofocus: i == 0,
                      disableScale: true,
                      useBackgroundFocus: true,
                      borderRadius: 12,
                      autoScroll: true,
                      semanticLabel: profiles[i].name,
                      onSelect: _busy ? null : () => unawaited(_pick(profiles[i])),
                      child: InkWell(
                        canRequestFocus: false,
                        onTap: _busy ? null : () => unawaited(_pick(profiles[i])),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              _Avatar(client: widget.client, profile: profiles[i]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(profiles[i].name, style: theme.textTheme.titleMedium),
                                    if (profiles[i].id == current)
                                      Text(t.tofaExtras.currentProfile, style: theme.textTheme.bodySmall)
                                    else if (profiles[i].isKids)
                                      Text(t.addServer.tofaProfileKids, style: theme.textTheme.bodySmall),
                                  ],
                                ),
                              ),
                              if (profiles[i].isLocked) const AppIcon(Symbols.lock_rounded, fill: 1, size: 20),
                              if (profiles[i].id == current) const AppIcon(Symbols.check_rounded, fill: 1),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.client, required this.profile});

  final TofaClient client;
  final TofaProfile profile;

  @override
  Widget build(BuildContext context) {
    final url = client.profileAvatarUrl(profile);
    final initial = profile.name.isEmpty ? '?' : profile.name.characters.first.toUpperCase();
    return CircleAvatar(
      radius: 20,
      foregroundImage: url.isEmpty ? null : NetworkImage(url),
      onForegroundImageError: url.isEmpty ? null : (_, _) {},
      child: Text(initial),
    );
  }
}
