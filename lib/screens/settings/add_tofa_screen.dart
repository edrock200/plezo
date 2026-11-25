import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../services/tofa/tofa_api.dart';
import '../../services/tofa/tofa_auth_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../profile/pin_entry_dialog.dart';
import '../profile/profile_switch_screen.dart';
import 'connection_persistence.dart';

enum _Step { intro, code, servers, apiKey, profiles, busy }

/// Sign in to a tofa server: tofa's device flow (approve a code on
/// tofa's website, then pick a server and a tofa profile), or an admin API
/// key on a server address. See the `tofa-backend` skill.
class AddTofaScreen extends StatefulWidget {
  final Profile? targetProfile;

  const AddTofaScreen({super.key, this.targetProfile});

  @override
  State<AddTofaScreen> createState() => _AddTofaScreenState();
}

class _AddTofaScreenState extends State<AddTofaScreen> {
  _Step _step = _Step.intro;
  String? _error;
  TofaAuthService? _auth;
  TofaDeviceCode? _code;
  bool _cancelled = false;
  String? _accountToken;
  List<TofaAccountServer> _servers = const [];
  TofaSignInResult? _signedIn;
  List<TofaProfile> _profiles = const [];
  final String _deviceId = const Uuid().v4();

  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  final _codeButtonFocus = FocusNode();
  final _keyButtonFocus = FocusNode();
  final _urlFocus = FocusNode();
  final _keyFocus = FocusNode();
  final _connectFocus = FocusNode();
  final _cancelFocus = FocusNode();

  @override
  void dispose() {
    _cancelled = true;
    _auth?.close();
    _urlController.dispose();
    _keyController.dispose();
    for (final n in [_codeButtonFocus, _keyButtonFocus, _urlFocus, _keyFocus, _connectFocus, _cancelFocus]) {
      n.dispose();
    }
    super.dispose();
  }

  Future<TofaAuthService> _service() async {
    return _auth ??= TofaAuthService(headers: await TofaClientHeaders.resolve(_deviceId));
  }

  String _message(Object error) {
    final reason = error is TofaSignInException ? error.reason : TofaSignInFailure.unknown;
    return switch (reason) {
      TofaSignInFailure.expired => t.addServer.tofaErrorExpired,
      TofaSignInFailure.denied => t.addServer.tofaErrorDenied,
      TofaSignInFailure.network => t.addServer.tofaErrorNetwork,
      TofaSignInFailure.notTofa => t.addServer.tofaErrorNotTofa,
      TofaSignInFailure.unauthorized => t.addServer.tofaErrorUnauthorized,
      TofaSignInFailure.noServers => t.addServer.tofaErrorNoServers,
      TofaSignInFailure.unknown => t.addServer.tofaErrorUnknown,
    };
  }

  void _fail(Object error, {_Step back = _Step.intro}) {
    appLogger.w('tofa sign-in failed', error: error is TofaSignInException ? error.reason : error.runtimeType);
    if (!mounted) return;
    setState(() {
      _error = _message(error);
      _step = back;
    });
  }

  // --- Device flow -----------------------------------------------------------

  Future<void> _startCode() async {
    setState(() {
      _error = null;
      _step = _Step.busy;
      _cancelled = false;
    });
    try {
      final auth = await _service();
      final code = await auth.startDeviceFlow();
      if (!mounted) return;
      setState(() {
        _code = code;
        _step = _Step.code;
      });
      final grant = await auth.waitForApproval(code, isCancelled: () => _cancelled || !mounted);
      if (!mounted || _cancelled) return;
      _accountToken = grant['access_token']?.toString();
      setState(() => _step = _Step.busy);
      final servers = await auth.listServers(_accountToken!);
      if (!mounted) return;
      if (servers.isEmpty) throw const TofaSignInException(TofaSignInFailure.noServers);
      if (servers.length == 1) {
        await _chooseServer(servers.single);
      } else {
        setState(() {
          _servers = servers;
          _step = _Step.servers;
        });
      }
    } catch (e) {
      if (_cancelled) return;
      _fail(e);
    }
  }

  void _cancelCode() {
    setState(() {
      _cancelled = true;
      _code = null;
      _step = _Step.intro;
    });
  }

  Future<void> _chooseServer(TofaAccountServer server) async {
    setState(() => _step = _Step.busy);
    try {
      final auth = await _service();
      final result = await auth.signInToServer(_accountToken!, server);
      await _afterSignIn(result);
    } catch (e) {
      _fail(e);
    }
  }

  // --- API key ---------------------------------------------------------------

  Future<void> _connectWithKey() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) return;
    setState(() {
      _error = null;
      _step = _Step.busy;
    });
    try {
      final auth = await _service();
      final withScheme = url.startsWith('http://') || url.startsWith('https://') ? url : 'http://$url';
      final result = await auth.signInWithApiKey(withScheme, key);
      await _afterSignIn(result);
    } catch (e) {
      _fail(e, back: _Step.apiKey);
    }
  }

  // --- Profiles --------------------------------------------------------------

  Future<void> _afterSignIn(TofaSignInResult result) async {
    _signedIn = result;
    final auth = await _service();
    List<TofaProfile> profiles;
    try {
      profiles = await auth.fetchProfiles(result.baseUrl, result.tokens.accessToken);
    } catch (_) {
      profiles = const [];
    }
    if (!mounted) return;
    if (profiles.length <= 1) {
      await _finish(profiles.isEmpty ? null : profiles.single);
      return;
    }
    setState(() {
      _profiles = profiles;
      _step = _Step.profiles;
    });
  }

  Future<void> _chooseProfile(TofaProfile profile) async {
    String? profileToken;
    if (profile.isLocked) {
      final pin = await showPinEntryDialog(context, t.addServer.tofaProfilePin(name: profile.name));
      if (pin == null || !mounted) return;
      setState(() => _step = _Step.busy);
      try {
        final result = _signedIn!;
        profileToken = await (await _service()).verifyPin(result.baseUrl, result.tokens.accessToken, profile.id, pin);
      } catch (e) {
        _fail(e, back: _Step.profiles);
        return;
      }
    }
    await _finish(profile, profileToken: profileToken);
  }

  Future<void> _finish(TofaProfile? profile, {String? profileToken}) async {
    final result = _signedIn!;
    setState(() => _step = _Step.busy);
    final profileId = profile == null || profile.isPrimary ? (profile?.id ?? '') : profile.id;
    final now = DateTime.now();
    final connection = TofaConnection(
      id: TofaConnection.compoundId(serverId: result.serverId, userId: result.userId, profileId: profileId),
      baseUrl: result.baseUrl,
      fallbackUrls: result.fallbackUrls,
      serverName: result.serverName,
      serverId: result.serverId,
      userId: result.userId,
      userName: result.userName,
      accessToken: result.tokens.accessToken,
      refreshToken: result.tokens.refreshToken,
      accessTokenExpiresAt: result.tokens.expiresAt,
      isApiKey: result.isApiKey,
      isAdministrator: result.isAdministrator,
      deviceId: _deviceId,
      profileId: profileId,
      profileName: profile?.name ?? '',
      profileAvatarUrl: profile?.avatarUrl,
      profileToken: profileToken,
      profileHasPin: profile?.isLocked ?? false,
      createdAt: now,
      lastAuthenticatedAt: now,
    );
    try {
      await _persist(connection);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _persist(TofaConnection connection) async {
    if (!mounted) return;
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return;
    final targetProfile = widget.targetProfile;
    var boundProfile = targetProfile ?? activeProvider.active;
    // As for Jellyfin: with profiles but none active, ask which one gets the
    // server; with no profiles at all, the first sign-in creates one.
    if (targetProfile == null && activeProvider.active == null && activeProvider.profiles.isNotEmpty) {
      await Navigator.of(
        context,
        rootNavigator: true,
      ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
      if (!mounted) return;
      boundProfile = activeProvider.active;
      if (boundProfile == null) {
        setState(() {
          _error = t.messages.noProfilesAvailable;
          _step = _Step.intro;
        });
        return;
      }
    }
    Profile? firstRunProfile;
    if (targetProfile == null && boundProfile == null && activeProvider.profiles.isEmpty) {
      final now = DateTime.now();
      firstRunProfile = Profile.local(
        id: 'local-${const Uuid().v4()}',
        displayName: connection.profileName.isNotEmpty
            ? connection.profileName
            : (connection.userName.isNotEmpty ? connection.userName : connection.serverName),
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
      );
      boundProfile = firstRunProfile;
    }
    final bindProfile = boundProfile;
    if (bindProfile == null) {
      setState(() {
        _error = t.messages.noProfilesAvailable;
        _step = _Step.intro;
      });
      return;
    }
    await persistAndBindConnection(
      context: context,
      connection: connection,
      bindToProfile: ProfileConnection(
        profileId: bindProfile.id,
        connectionId: connection.id,
        userToken: null,
        userIdentifier: connection.userId,
        tokenAcquiredAt: DateTime.now(),
      ),
      firstRunProfile: firstRunProfile,
    );
    if (!mounted) return;
    if (bindProfile.id == activeProvider.activeId) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // --- UI --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.addServer.addTofaTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(24),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: _body(context)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorText(BuildContext context) => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    switch (_step) {
      case _Step.busy:
        return const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: LoadingIndicatorBox(size: 32)),
        );
      case _Step.intro:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.addServer.tofaIntro,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: 24),
            FocusableButton(
              focusNode: _codeButtonFocus,
              autofocus: true,
              useBackgroundFocus: true,
              onPressed: _startCode,
              onNavigateDown: _keyButtonFocus.requestFocus,
              child: FilledButton.icon(
                onPressed: _startCode,
                icon: const AppIcon(Symbols.qr_code_2_rounded, fill: 1),
                label: Text(t.addServer.tofaSignInWithCode),
              ),
            ),
            const SizedBox(height: 12),
            FocusableButton(
              focusNode: _keyButtonFocus,
              useBackgroundFocus: true,
              onPressed: () => setState(() {
                _error = null;
                _step = _Step.apiKey;
              }),
              onNavigateUp: _codeButtonFocus.requestFocus,
              child: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _error = null;
                  _step = _Step.apiKey;
                }),
                icon: const AppIcon(Symbols.key_rounded, fill: 1),
                label: Text(t.addServer.tofaUseApiKey),
              ),
            ),
            _errorText(context),
          ],
        );
      case _Step.code:
        final code = _code!;
        return Column(
          children: [
            Text(
              t.addServer.tofaCodeInstructions(url: code.verificationUri.replaceFirst(RegExp(r'^https?://'), '')),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: 24),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                code.userCode,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox.square(
              dimension: 168,
              child: QrImageView(
                data: code.verificationUriComplete,
                size: 168,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                semanticsLabel: t.addServer.tofaQrSemantics(url: code.verificationUriComplete),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LoadingIndicatorBox(size: 16),
                const SizedBox(width: 10),
                Text(t.addServer.tofaWaiting, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ],
            ),
            const SizedBox(height: 24),
            FocusableButton(
              focusNode: _cancelFocus,
              autofocus: true,
              useBackgroundFocus: true,
              onPressed: _cancelCode,
              child: OutlinedButton.icon(
                onPressed: _cancelCode,
                icon: const AppIcon(Symbols.close_rounded, fill: 1),
                label: Text(t.common.cancel),
              ),
            ),
          ],
        );
      case _Step.servers:
        return _choiceList(
          context,
          title: t.addServer.tofaChooseServer,
          labels: [for (final s in _servers) s.name],
          onSelected: (i) => _chooseServer(_servers[i]),
        );
      case _Step.profiles:
        return _choiceList(
          context,
          title: t.addServer.tofaChooseProfile,
          labels: [for (final p in _profiles) p.name],
          icons: [for (final p in _profiles) p.isLocked ? Symbols.lock_rounded : Symbols.person_rounded],
          onSelected: (i) => _chooseProfile(_profiles[i]),
        );
      case _Step.apiKey:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FocusableTextFormField(
              controller: _urlController,
              focusNode: _urlFocus,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onNavigateDown: _keyFocus.requestFocus,
              onFieldSubmitted: (_) => _keyFocus.requestFocus(),
              decoration: InputDecoration(
                labelText: t.addServer.tofaServerUrl,
                helperText: t.addServer.tofaServerUrlHelper,
                helperMaxLines: 3,
                prefixIcon: const AppIcon(Symbols.dns_rounded, fill: 1),
              ),
            ),
            const SizedBox(height: 12),
            FocusableTextFormField(
              controller: _keyController,
              focusNode: _keyFocus,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onNavigateUp: _urlFocus.requestFocus,
              onNavigateDown: _connectFocus.requestFocus,
              onFieldSubmitted: (_) => _connectWithKey(),
              decoration: InputDecoration(
                labelText: t.addServer.tofaApiKey,
                helperText: t.addServer.tofaApiKeyHelper,
                helperMaxLines: 3,
                prefixIcon: const AppIcon(Symbols.key_rounded, fill: 1),
              ),
            ),
            const SizedBox(height: 20),
            FocusableButton(
              focusNode: _connectFocus,
              useBackgroundFocus: true,
              onPressed: _connectWithKey,
              onNavigateUp: _keyFocus.requestFocus,
              child: FilledButton(onPressed: _connectWithKey, child: Text(t.addServer.tofaConnect)),
            ),
            _errorText(context),
          ],
        );
    }
  }

  Widget _choiceList(
    BuildContext context, {
    required String title,
    required List<String> labels,
    List<IconData>? icons,
    required void Function(int index) onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          FocusableButton(
            autofocus: i == 0,
            useBackgroundFocus: true,
            onPressed: () => onSelected(i),
            child: OutlinedButton.icon(
              onPressed: () => onSelected(i),
              icon: AppIcon(icons?[i] ?? Symbols.dns_rounded, fill: 1),
              label: Align(alignment: Alignment.centerLeft, child: Text(labels[i])),
            ),
          ),
        ],
        _errorText(context),
      ],
    );
  }
}
