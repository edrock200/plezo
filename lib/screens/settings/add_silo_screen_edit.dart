part of 'add_silo_screen.dart';

// "Edit" / "Sign in again" on a saved Silo connection
// ([AddSiloScreen.editConnection]). The add-server steps run against that
// connection: the address step starts filled in and only accepts the same
// server (by `GET /api/v2/system/identity`); a new address alone can be saved
// keeping the current sign-in; a sign-in by code, password or phone as the
// same account and Silo profile replaces the session in place (same id, so
// every binding and the download scope stay), and the replaced session is
// revoked with its old tokens. Another account or Silo profile is another
// connection: the screen says where it goes (a new Plezilo profile when the
// chosen one already uses this server, the rule in silo_accounts.dart) and
// saves it only on Continue, leaving the edited connection as it is.

/// The edit flow's own state on [_AddSiloScreenState].
class _SiloEditState {
  final saveAddressFocus = FocusNode(debugLabel: 'AddSilo:EditSaveAddress');
  final confirmFocus = FocusNode(debugLabel: 'AddSilo:EditConfirm');
  final confirmBackFocus = FocusNode(debugLabel: 'AddSilo:EditConfirmBack');

  /// A sign-in as another account or Silo profile, waiting for Continue.
  SiloConnection? pending;

  /// What Continue does with [pending], as shown on screen.
  String? pendingTitle;
  String? pendingBody;

  void dispose() {
    saveAddressFocus.dispose();
    confirmFocus.dispose();
    confirmBackFocus.dispose();
  }
}

extension _SiloEditFlow on _AddSiloScreenState {
  SiloConnection? get _edited => widget.editConnection;

  /// The screen title while editing.
  String _editTitle(SiloConnection edited) => widget.signInAgain
      ? t.siloEditConnection.signInAgainTitle(server: edited.serverName)
      : t.siloEditConnection.editTitle(server: edited.serverName);

  /// Fill in the saved address and username.
  void _initEdit() {
    final edited = _edited;
    if (edited == null) return;
    _urlController.text = edited.baseUrl;
    _usernameController.text = edited.userName;
    // "Sign in again": the address is known, go straight to the sign-in.
    if (widget.signInAgain) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _step == _Step.address && _server == null && !busy) unawaited(_probe());
      });
    }
  }

  /// Refuse another server at the typed address. True when [server] is the
  /// edited connection's (or nothing is being edited).
  bool _editAcceptsServer(SiloServerInfo server) {
    final edited = _edited;
    if (edited == null || siloIsSameServer(edited, server)) return true;
    appLogger.i('[silo-edit] the address answered as another server; refused');
    setErrorText(t.siloEditConnection.wrongServer(server: edited.serverName));
    requestFocusAfterFrame(_urlFocus);
    return false;
  }

  /// The probed server is the edited one at a new address: offer to save it
  /// alone, keeping the sign-in.
  bool get _editAddressPending {
    final edited = _edited;
    final server = _server;
    return edited != null && server != null && siloAddressChanged(edited, server.baseUrl);
  }

  /// The "Save the new address" button's node while it is shown.
  FocusNode? get _editAddressFocus => _editAddressPending ? _edit.saveAddressFocus : null;

  /// The intro above the address field while editing.
  List<Widget> _buildEditIntro(ThemeData theme) {
    final edited = _edited;
    if (edited == null) return const [];
    return [
      Text(
        t.siloEditConnection.intro(account: siloAccountLabel(edited), server: edited.serverName),
        style: theme.textTheme.bodyMedium,
      ),
      const SizedBox(height: 16),
    ];
  }

  /// "Save the new address" under the server card (a moved server whose
  /// sign-in still works needs nothing else).
  List<Widget> _buildEditAddressAction(ThemeData theme, SiloServerInfo server) {
    if (!_editAddressPending) return const [];
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return [
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _edit.saveAddressFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _changeServerFocus.requestFocus(),
        onNavigateDown: () {
          if (server.deviceLoginAvailable) {
            _codeFocus.requestFocus();
          } else if (server.passwordLoginAvailable) {
            _usernameFocus.requestFocus();
          }
        },
        onPressed: busy ? null : _saveEditedAddress,
        child: FilledButton.icon(
          onPressed: busy ? null : _saveEditedAddress,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.save_rounded, fill: 1),
          label: Text(t.siloEditConnection.saveAddress),
        ),
      ),
      const SizedBox(height: 8),
      Text(t.siloEditConnection.saveAddressHint, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
    ];
  }

  SiloConnectionEditor _editor(SiloAuthService auth) {
    MultiServerManager? manager;
    try {
      manager = Provider.of<MultiServerProvider>(context, listen: false).serverManager;
    } on ProviderNotFoundException {
      manager = null;
    }
    return SiloConnectionEditor(registry: context.read<ConnectionRegistry>(), auth: auth, serverManager: manager);
  }

  /// Rebind the active Plezilo profile, so a live client picks the change up.
  Future<void> _rebindAfterEdit() async {
    final active = context.read<ActiveProfileProvider>().activeId;
    if (active == null) return;
    await context.read<ActiveProfileBinder>().rebindIfActive(active);
  }

  Future<void> _saveEditedAddress() async {
    final edited = _edited;
    final server = _server;
    if (edited == null || server == null || busy) return;
    final saved = await runAsync<bool>(
      () async {
        final editor = _editor(await _authService());
        await editor.changeAddress(edited.id, server.baseUrl);
        if (!mounted) return false;
        await _rebindAfterEdit();
        return true;
      },
      errorMapper: (e) {
        appLogger.e('Silo address change failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
    if (saved != true || !mounted) return;
    showMainSnackBar(t.siloEditConnection.addressSaved(server: edited.serverName));
    Navigator.of(context).pop(true);
  }

  /// Saving [connection] (built from this sign-in and the picked Silo
  /// profile) from the edit screen. The same id is saved in place; another
  /// account or Silo profile first says where it goes. False when saving
  /// failed (the error is shown) or the screen went away.
  Future<bool> _finishEdit(SiloConnection edited, SiloConnection connection) async {
    final kind = siloEditKind(edited, connection);
    if (kind == SiloEditKind.sameConnection) return _saveSignedInAgain(connection);
    final preview = await runAsync<(String, String)>(
      () => _previewOtherConnection(edited, connection, kind),
      errorMapper: (e) => t.addServer.signInFailed(error: e.toString()),
    );
    if (preview == null || !mounted) return false;
    _disposeDeviceFlow();
    _setEditState(() {
      _edit
        ..pending = connection
        ..pendingTitle = preview.$1
        ..pendingBody = preview.$2;
      _completingApproval = false;
      _step = _Step.editConfirm;
    });
    requestFocusAfterFrame(_edit.confirmFocus);
    return true;
  }

  /// The title and text naming where [connection] goes on Continue, computed
  /// with the rule `_persistAndExit` applies.
  Future<(String, String)> _previewOtherConnection(
    SiloConnection edited,
    SiloConnection connection,
    SiloEditKind kind,
  ) async {
    final activeProvider = context.read<ActiveProfileProvider>();
    final joinsRegistry = context.read<ProfileConnectionRegistry>();
    final registry = context.read<ConnectionRegistry>();
    final bound = widget.targetProfile ?? activeProvider.active;
    final title = kind == SiloEditKind.otherAccount
        ? t.siloEditConnection.otherAccountTitle
        : t.siloEditConnection.otherProfileTitle;
    final account = siloAccountLabel(connection);
    final previous = siloAccountLabel(edited);
    if (bound == null) return (title, t.siloEditConnection.otherKeepsBoth(account: account, previous: previous));
    final joinRows = await joinsRegistry.listForProfile(bound.id);
    final connectionsById = {for (final c in await registry.list()) c.id: c};
    final other = otherSiloConnectionOnServer(
      incoming: connection,
      joinRows: joinRows,
      connectionsById: connectionsById,
    );
    if (other == null) {
      return (
        title,
        t.siloEditConnection.otherJoinsProfile(account: account, previous: previous, profile: bound.displayName),
      );
    }
    final newName = newProfileNameForSiloConnection(connection, activeProvider.profiles.map((p) => p.displayName));
    return (
      title,
      t.siloEditConnection.otherNewProfile(
        account: account,
        previous: previous,
        profile: newName,
        current: bound.displayName,
      ),
    );
  }

  /// A new session for the same account and Silo profile: replace the stored
  /// row in place (id, bindings and download scope stay) and revoke the old
  /// session.
  Future<bool> _saveSignedInAgain(SiloConnection connection) async {
    final auth = _auth;
    if (auth == null) return false;
    var saved = false;
    await runAsync<void>(
      () async {
        final editor = _editor(auth);
        final registry = context.read<ConnectionRegistry>();
        // From here the session belongs to the saved connection.
        _handedOff = true;
        try {
          await editor.replaceSession(connection);
        } catch (_) {
          final stored = await registry.get(connection.id).catchError((_) => null);
          _handedOff = stored is SiloConnection && stored.refreshToken == connection.refreshToken;
          rethrow;
        }
        saved = true;
        if (!mounted) return;
        await _rebindAfterEdit();
      },
      errorMapper: (e) {
        appLogger.e('Silo sign-in again failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
    if (!saved || !mounted) return saved;
    showMainSnackBar(t.siloEditConnection.signedInAgain(server: connection.serverName));
    Navigator.of(context).pop(true);
    return true;
  }

  /// Continue on the confirmation: save the other account or Silo profile
  /// with the usual rules.
  Future<void> _confirmOtherConnection() async {
    final pending = _edit.pending;
    if (pending == null || busy) return;
    await runAsync<void>(
      () async {
        if (await _persistAndExit(pending)) _edit.pending = null;
      },
      errorMapper: (e) {
        appLogger.e('Silo edit: saving another account failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
  }

  /// Back on the confirmation: pick another Silo profile (the sign-in stays).
  void _backFromEditConfirm() {
    if (busy) return;
    setErrorText(null);
    _setEditState(() {
      _edit.pending = null;
      _step = _profiles.isEmpty ? _Step.signIn : _Step.profile;
    });
    if (_profiles.isEmpty) _focusSignInStep(preferPassword: true);
  }

  List<Widget> _buildEditConfirm(ThemeData theme) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return [
      Semantics(
        header: true,
        liveRegion: true,
        child: Text(_edit.pendingTitle ?? '', style: theme.textTheme.titleLarge),
      ),
      const SizedBox(height: 12),
      Text(_edit.pendingBody ?? '', style: theme.textTheme.bodyLarge?.copyWith(color: muted)),
      const SizedBox(height: 24),
      FocusableButton(
        focusNode: _edit.confirmFocus,
        autofocus: true,
        useBackgroundFocus: true,
        onNavigateDown: () => _edit.confirmBackFocus.requestFocus(),
        onPressed: busy ? null : _confirmOtherConnection,
        child: FilledButton.icon(
          onPressed: busy ? null : _confirmOtherConnection,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.person_add_rounded, fill: 1),
          label: Text(t.siloEditConnection.continueAdding),
        ),
      ),
      const SizedBox(height: 12),
      FocusableButton(
        focusNode: _edit.confirmBackFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _edit.confirmFocus.requestFocus(),
        onPressed: busy ? null : _backFromEditConfirm,
        child: OutlinedButton.icon(
          onPressed: busy ? null : _backFromEditConfirm,
          icon: const AppIcon(Symbols.arrow_back_rounded, fill: 1),
          label: Text(t.siloEditConnection.back),
        ),
      ),
      ...buildInlineError(theme),
    ];
  }

  /// Whether [profile] is the edited connection's Silo profile of the same
  /// account.
  bool _isEditedProfile(SiloProfile profile) {
    final edited = _edited;
    final signIn = _signIn;
    return edited != null && signIn != null && signIn.account.id == edited.userId && profile.id == edited.profileId;
  }
}
