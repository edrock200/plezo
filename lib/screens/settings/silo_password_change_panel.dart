import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../services/silo/silo_password_change.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/loading_indicator_box.dart';

/// The text for a "Choose a new password" error.
@visibleForTesting
String siloPasswordFormErrorText(SiloPasswordFormError error, SiloPasswordRequirements requirements) =>
    switch (error.kind) {
      SiloPasswordFormErrorKind.enterTemporaryPassword => t.addServer.siloPasswordErrorEnterTemporary,
      SiloPasswordFormErrorKind.enterNewPassword => t.addServer.siloPasswordErrorEnterNew,
      SiloPasswordFormErrorKind.mismatch => t.addServer.siloPasswordErrorMismatch,
      SiloPasswordFormErrorKind.tooShort => t.addServer.siloPasswordErrorTooShort(
        count: requirements.minimumLength.toString(),
      ),
      SiloPasswordFormErrorKind.tooLong => t.addServer.siloPasswordErrorTooLong,
      SiloPasswordFormErrorKind.wrongTemporaryPassword => t.addServer.siloPasswordErrorWrongTemporary,
      SiloPasswordFormErrorKind.rejected => error.detail ?? t.addServer.siloPasswordErrorRejected,
      SiloPasswordFormErrorKind.rateLimited => t.addServer.siloPasswordErrorRateLimited,
      SiloPasswordFormErrorKind.notPasswordAccount => t.addServer.siloPasswordErrorNotPasswordAccount,
      SiloPasswordFormErrorKind.notAllowed => t.addServer.siloPasswordErrorNotAllowed,
      SiloPasswordFormErrorKind.failed => t.addServer.siloPasswordErrorFailed,
      SiloPasswordFormErrorKind.notChanged => t.addServer.siloPasswordErrorNotChanged,
    };

/// "Choose a new password", shown on the Silo sign-in screen when the account
/// holds a temporary password an admin set (phones, tablets, desktops; TVs
/// say where to change it instead). [controller] owns the rules; this lays
/// them out for touch, keyboard and D-pad.
class SiloPasswordChangePanel extends StatefulWidget {
  final SiloPasswordChangeController controller;

  /// "Sign out": abandon this sign-in.
  final VoidCallback onSignOut;

  const SiloPasswordChangePanel({super.key, required this.controller, required this.onSignOut});

  @override
  State<SiloPasswordChangePanel> createState() => _SiloPasswordChangePanelState();
}

class _SiloPasswordChangePanelState extends State<SiloPasswordChangePanel> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirmation = TextEditingController();
  final _currentFocus = FocusNode(debugLabel: 'SiloPassword:Current');
  final _newFocus = FocusNode(debugLabel: 'SiloPassword:New');
  final _confirmationFocus = FocusNode(debugLabel: 'SiloPassword:Confirm');
  final _saveFocus = FocusNode(debugLabel: 'SiloPassword:Save');
  final _actionFocus = FocusNode(debugLabel: 'SiloPassword:Action');
  final _signOutFocus = FocusNode(debugLabel: 'SiloPassword:SignOut');

  late SiloPasswordChangePhase _phase = widget.controller.value.phase;
  late int _errorCount = widget.controller.value.errorCount;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onState);
    _focusAfterFrame(_currentFocus);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onState);
    for (final c in [_current, _new, _confirmation]) {
      c.dispose();
    }
    for (final node in [_currentFocus, _newFocus, _confirmationFocus, _saveFocus, _actionFocus, _signOutFocus]) {
      node.dispose();
    }
    super.dispose();
  }

  void _focusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.canRequestFocus) node.requestFocus();
    });
  }

  void _onState() {
    final state = widget.controller.value;
    final wasForm = _phase == SiloPasswordChangePhase.editing || _phase == SiloPasswordChangePhase.saving;
    if (state.phase != _phase) {
      if (wasForm && !state.showsForm) {
        // The password may have changed: the form closes and its fields are
        // cleared, so nothing can send the temporary password again.
        _current.clear();
        _new.clear();
        _confirmation.clear();
        _focusAfterFrame(_actionFocus);
      } else if (!wasForm && state.showsForm) {
        _focusAfterFrame(_currentFocus);
      } else if (state.phase == SiloPasswordChangePhase.refreshFailed ||
          state.phase == SiloPasswordChangePhase.unconfirmed) {
        _focusAfterFrame(_actionFocus);
      }
      _phase = state.phase;
    }
    if (state.errorCount != _errorCount) {
      _errorCount = state.errorCount;
      // Back on the field the error is most likely about.
      final target = switch (state.error?.kind) {
        SiloPasswordFormErrorKind.enterTemporaryPassword ||
        SiloPasswordFormErrorKind.wrongTemporaryPassword ||
        SiloPasswordFormErrorKind.notChanged => _currentFocus,
        SiloPasswordFormErrorKind.mismatch => _confirmationFocus,
        SiloPasswordFormErrorKind.enterNewPassword ||
        SiloPasswordFormErrorKind.tooShort ||
        SiloPasswordFormErrorKind.tooLong ||
        SiloPasswordFormErrorKind.rejected => _newFocus,
        _ => null,
      };
      if (target != null) _focusAfterFrame(target);
    }
  }

  void _save() {
    if (widget.controller.value.phase != SiloPasswordChangePhase.editing) return;
    widget.controller.submit(current: _current.text, newPassword: _new.text, confirmation: _confirmation.text);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SiloPasswordChangeState>(
      valueListenable: widget.controller,
      builder: (context, state, _) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: .stretch,
          children: state.showsForm ? _buildForm(theme, state) : _buildOutcome(theme, state),
        );
      },
    );
  }

  Widget _heading(ThemeData theme, String title, String lead) => Column(
    crossAxisAlignment: .start,
    children: [
      Semantics(header: true, child: Text(title, style: theme.textTheme.titleLarge)),
      const SizedBox(height: 4),
      Text(
        lead,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
      ),
    ],
  );

  Widget _passwordField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    required bool enabled,
    FocusNode? up,
    FocusNode? down,
    bool last = false,
  }) => FocusableTextFormField(
    controller: controller,
    focusNode: focusNode,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    enabled: enabled,
    keyboardType: TextInputType.visiblePassword,
    onNavigateUp: up == null ? null : () => up.requestFocus(),
    onNavigateDown: down == null ? null : () => down.requestFocus(),
    textInputAction: last ? TextInputAction.go : TextInputAction.next,
    onFieldSubmitted: enabled ? (_) => last ? _save() : down?.requestFocus() : null,
    decoration: InputDecoration(labelText: label, prefixIcon: AppIcon(icon, fill: 1)),
  );

  List<Widget> _buildForm(ThemeData theme, SiloPasswordChangeState state) {
    final busy = state.isBusy;
    final name = state.accountName?.trim();
    final error = state.error;
    return [
      _heading(
        theme,
        t.addServer.siloPasswordChangeTitle,
        name == null || name.isEmpty
            ? t.addServer.siloPasswordChangeLeadNoName
            : t.addServer.siloPasswordChangeLead(account: name),
      ),
      const SizedBox(height: 16),
      _passwordField(
        controller: _current,
        focusNode: _currentFocus,
        label: t.addServer.siloTemporaryPassword,
        icon: Symbols.key_rounded,
        enabled: !busy,
        down: _newFocus,
      ),
      const SizedBox(height: 12),
      _passwordField(
        controller: _new,
        focusNode: _newFocus,
        label: t.addServer.siloNewPassword,
        icon: Symbols.lock_rounded,
        enabled: !busy,
        up: _currentFocus,
        down: _confirmationFocus,
      ),
      const SizedBox(height: 12),
      _passwordField(
        controller: _confirmation,
        focusNode: _confirmationFocus,
        label: t.addServer.siloConfirmNewPassword,
        icon: Symbols.lock_rounded,
        enabled: !busy,
        up: _newFocus,
        down: _saveFocus,
        last: true,
      ),
      const SizedBox(height: 8),
      Text(
        t.addServer.siloPasswordMinimum(count: state.requirements.minimumLength.toString()),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
      ),
      if (error != null) ...[
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(
            siloPasswordFormErrorText(error, state.requirements),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ),
      ],
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _saveFocus,
        useBackgroundFocus: true,
        onNavigateUp: () => _confirmationFocus.requestFocus(),
        onNavigateDown: () => _signOutFocus.requestFocus(),
        onPressed: busy ? null : _save,
        child: FilledButton.icon(
          onPressed: busy ? null : _save,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.check_rounded, fill: 1),
          label: Text(busy ? t.addServer.siloSavingPassword : t.addServer.siloSavePassword),
        ),
      ),
      const SizedBox(height: 8),
      _signOutButton(busy: busy, up: _saveFocus),
    ];
  }

  List<Widget> _buildOutcome(ThemeData theme, SiloPasswordChangeState state) {
    final changed =
        state.phase == SiloPasswordChangePhase.refreshFailed || state.phase == SiloPasswordChangePhase.refreshing;
    final busy = state.isBusy;
    final VoidCallback? onAction = busy
        ? null
        : changed
        ? () => widget.controller.retryRefresh()
        : () => widget.controller.confirmChange();
    final label = !busy
        ? t.addServer.siloTryAgain
        : changed
        ? t.addServer.siloTryingAgain
        : t.addServer.siloCheckingPassword;
    return [
      Semantics(
        liveRegion: true,
        child: _heading(
          theme,
          changed ? t.addServer.siloPasswordChangedTitle : t.addServer.siloPasswordNotConfirmedTitle,
          changed ? t.addServer.siloPasswordChangedLead : t.addServer.siloPasswordNotConfirmedLead,
        ),
      ),
      const SizedBox(height: 16),
      FocusableButton(
        focusNode: _actionFocus,
        useBackgroundFocus: true,
        onNavigateDown: () => _signOutFocus.requestFocus(),
        onPressed: onAction,
        child: FilledButton.icon(
          onPressed: onAction,
          icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.refresh_rounded, fill: 1),
          label: Text(label),
        ),
      ),
      const SizedBox(height: 8),
      _signOutButton(busy: busy, up: _actionFocus),
    ];
  }

  Widget _signOutButton({required bool busy, required FocusNode up}) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: FocusableButton(
      focusNode: _signOutFocus,
      useBackgroundFocus: true,
      onNavigateUp: () => up.requestFocus(),
      onPressed: busy ? null : widget.onSignOut,
      child: TextButton.icon(
        onPressed: busy ? null : widget.onSignOut,
        icon: const AppIcon(Symbols.logout_rounded, fill: 1),
        label: Text(t.addServer.siloSignOut),
      ),
    ),
  );
}
