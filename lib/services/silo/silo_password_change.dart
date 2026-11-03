import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import 'silo_api.dart';
import 'silo_auth_service.dart';

// Temporary passwords (Silo Android #790, silo-apple #874): an admin can make
// an account's password temporary. Until the account replaces it, the server
// answers everything except `GET /account/me`, `GET /account/password/capability`,
// `POST /account/password` and sign-out with `403 password_change_required`
// (`SiloPasswordChangeRequiredException`). On phones, tablets and desktops the
// sign-in screen opens "Choose a new password"; TVs say where to change it.

/// `GET /api/v2/account/password/capability`.
class SiloPasswordCapability {
  final String state;

  /// Absent unless [state] is `available`.
  final bool? allowed;
  final int? minimumPasswordLength;
  final int? maximumPasswordBytes;

  const SiloPasswordCapability({
    required this.state,
    this.allowed,
    this.minimumPasswordLength,
    this.maximumPasswordBytes,
  });

  static SiloPasswordCapability? fromJson(Object? json) {
    if (json is! Map) return null;
    final state = json['state'];
    if (state is! String) return null;
    int? count(Object? value) => value is num ? value.toInt() : null;
    return SiloPasswordCapability(
      state: state,
      allowed: switch (json['allowed']) {
        final bool value => value,
        _ => null,
      },
      minimumPasswordLength: count(json['minimum_password_length']),
      maximumPasswordBytes: count(json['maximum_password_bytes']),
    );
  }
}

/// Why a new password and its confirmation cannot be sent.
enum SiloNewPasswordProblem { empty, mismatch, tooShort, tooLong }

/// A new password's limits. The server enforces them; the form checks them
/// first so a typo does not spend an attempt from the password-change budget.
class SiloPasswordRequirements {
  /// Fewest characters, counted in Unicode code points as the server does.
  final int minimumLength;

  /// Most UTF-8 bytes.
  final int maximumBytes;

  const SiloPasswordRequirements({required this.minimumLength, required this.maximumBytes});

  /// silo-server's limits, for when the capability cannot be read.
  static const serverDefault = SiloPasswordRequirements(minimumLength: 8, maximumBytes: 72);

  /// The capability's limits; a missing or non-positive one keeps the default.
  factory SiloPasswordRequirements.from(SiloPasswordCapability capability) {
    final minimum = capability.minimumPasswordLength;
    final maximum = capability.maximumPasswordBytes;
    return SiloPasswordRequirements(
      minimumLength: minimum != null && minimum > 0 ? minimum : serverDefault.minimumLength,
      maximumBytes: maximum != null && maximum > 0 ? maximum : serverDefault.maximumBytes,
    );
  }

  /// Why [password] and its [confirmation] cannot be sent, or null.
  SiloNewPasswordProblem? problem(String password, String confirmation) {
    if (password.isEmpty) return SiloNewPasswordProblem.empty;
    if (password != confirmation) return SiloNewPasswordProblem.mismatch;
    if (password.runes.length < minimumLength) return SiloNewPasswordProblem.tooShort;
    if (utf8.encode(password).length > maximumBytes) return SiloNewPasswordProblem.tooLong;
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SiloPasswordRequirements && other.minimumLength == minimumLength && other.maximumBytes == maximumBytes;

  @override
  int get hashCode => Object.hash(minimumLength, maximumBytes);
}

/// Why the server refused a password change (a 4xx: nothing changed).
enum SiloPasswordChangeRefusal {
  /// 422 naming `body.current_password`: the temporary password is wrong.
  wrongCurrentPassword,

  /// Another 422: the new password broke a rule ([SiloPasswordChangeRefused.detail] names it).
  rejected,

  /// 429.
  rateLimited,

  /// 409: the account does not sign in with a Silo password.
  notPasswordAccount,

  /// 403: this session may not change the password (an impersonation).
  notAllowed,

  /// Any other 4xx.
  other,
}

/// The answer to `POST /api/v2/account/password`.
sealed class SiloPasswordChangeResult {
  const SiloPasswordChangeResult();

  /// Maps a response: 204 changed it; a 4xx is the server's own refusal; any
  /// other answer (a 5xx, an unexpected 2xx) leaves the outcome unknown.
  static SiloPasswordChangeResult fromResponse(int statusCode, Object? data) {
    if (statusCode == 204) return const SiloPasswordChanged();
    if (statusCode < 400 || statusCode >= 500) return const SiloPasswordChangeUnknown();
    final errors = data is Map ? data['errors'] : null;
    final first = errors is List ? errors.whereType<Map>().firstOrNull : null;
    final firstDetail = first?['detail'];
    final detail = firstDetail is String && firstDetail.trim().isNotEmpty ? firstDetail.trim() : null;
    final refusal = switch (statusCode) {
      422 when first?['location'] == 'body.current_password' => SiloPasswordChangeRefusal.wrongCurrentPassword,
      422 => SiloPasswordChangeRefusal.rejected,
      429 => SiloPasswordChangeRefusal.rateLimited,
      409 => SiloPasswordChangeRefusal.notPasswordAccount,
      403 => SiloPasswordChangeRefusal.notAllowed,
      _ => SiloPasswordChangeRefusal.other,
    };
    return SiloPasswordChangeRefused(
      statusCode,
      refusal,
      detail: refusal == SiloPasswordChangeRefusal.rejected ? detail : null,
    );
  }
}

class SiloPasswordChanged extends SiloPasswordChangeResult {
  const SiloPasswordChanged();
}

class SiloPasswordChangeRefused extends SiloPasswordChangeResult {
  final int statusCode;
  final SiloPasswordChangeRefusal refusal;

  /// For [SiloPasswordChangeRefusal.rejected]: the rule the new password broke.
  final String? detail;

  const SiloPasswordChangeRefused(this.statusCode, this.refusal, {this.detail});
}

/// No answer, or one that does not say whether the password changed.
class SiloPasswordChangeUnknown extends SiloPasswordChangeResult {
  const SiloPasswordChangeUnknown();
}

/// What "Choose a new password" needs from the signed-in account. All calls
/// are account-scoped, with no profile declared: the server refuses a
/// declared profile while the password is temporary.
abstract interface class SiloTemporaryPasswordAccount {
  /// `GET /api/v2/account/me`; throws when it cannot be read.
  Future<SiloAccount> readAccount();

  /// The server's limits for a new password; its defaults when they cannot be read.
  Future<SiloPasswordRequirements> passwordRequirements();

  /// `POST /api/v2/account/password`, sent once.
  Future<SiloPasswordChangeResult> changePassword(String current, String next);

  /// Replaces the restricted access token; true only when it rotated.
  Future<bool> refreshSessionAfterPasswordChange();
}

/// [SiloTemporaryPasswordAccount] over one [SiloApi] holding a fresh
/// sign-in's tokens. The refresh is [SiloApi.refreshTokens], the same
/// single-flight refresh every other request uses, so a proactive refresh
/// and the forced one never rotate the pair twice. Each refreshed pair is
/// reported through the api's `onTokensRefreshed` for the owner to keep.
class SiloTemporaryPasswordSession implements SiloTemporaryPasswordAccount {
  SiloTemporaryPasswordSession(this._api);

  final SiloApi _api;

  static const _readTimeout = Duration(seconds: 15);

  SiloTokens? get tokens => _api.tokens;

  @override
  Future<SiloAccount> readAccount() async {
    final data = await _api.getJson('/api/v2/account/me', profile: false, timeout: _readTimeout);
    final account = SiloAccount.fromJson(data);
    if (account == null) throw const SiloSignInException(SiloSignInFailure.missingAccount);
    return account;
  }

  @override
  Future<SiloPasswordRequirements> passwordRequirements() async {
    try {
      final data = await _api.getJson('/api/v2/account/password/capability', profile: false, timeout: _readTimeout);
      final capability = SiloPasswordCapability.fromJson(data);
      return capability == null ? SiloPasswordRequirements.serverDefault : SiloPasswordRequirements.from(capability);
    } catch (e) {
      appLogger.d('Silo: password capability unavailable; using the server defaults', error: e.runtimeType);
      return SiloPasswordRequirements.serverDefault;
    }
  }

  /// Sent once: a 401 refreshes the token for the next try but never resends
  /// (a resend would spend another attempt from the password-change budget, or
  /// send a temporary password the first request already replaced). Neither
  /// password is logged; both travel only in the body.
  @override
  Future<SiloPasswordChangeResult> changePassword(String current, String next) async {
    try {
      final response = await _api.request(
        'POST',
        '/api/v2/account/password',
        profile: false,
        body: {'current_password': current, 'new_password': next},
        resendAfterRefresh: false,
      );
      return SiloPasswordChangeResult.fromResponse(response.statusCode, response.data);
    } on MediaServerHttpException catch (e) {
      appLogger.d('Silo: password change got no answer', error: e.type);
      return const SiloPasswordChangeUnknown();
    }
  }

  @override
  Future<bool> refreshSessionAfterPasswordChange() async {
    final before = _api.accessToken;
    final refreshed = await _api.refreshTokens();
    final after = _api.accessToken;
    return refreshed != null && after != null && after != before;
  }

  void close() => _api.close();
}

/// Where "Choose a new password" is.
enum SiloPasswordChangePhase {
  /// The form is open.
  editing,

  /// The change, then the account read or refresh that follows it, is in flight.
  saving,

  /// The password changed but the refresh did not complete. The form stays
  /// closed: the temporary password it would send no longer works.
  refreshFailed,

  /// [refreshFailed]'s Try again, or the refresh after the change, is running.
  refreshing,

  /// The change failed and the account could not be read, so whether the
  /// password changed is unknown. The form stays closed so the change cannot
  /// be sent twice.
  unconfirmed,

  /// [unconfirmed]'s Try again: the account is being read again.
  checking,
}

/// Why the form shows an error.
enum SiloPasswordFormErrorKind {
  enterTemporaryPassword,
  enterNewPassword,
  mismatch,
  tooShort,
  tooLong,
  wrongTemporaryPassword,
  rejected,
  rateLimited,
  notPasswordAccount,
  notAllowed,
  failed,
  notChanged,
}

@immutable
class SiloPasswordFormError {
  final SiloPasswordFormErrorKind kind;

  /// For [SiloPasswordFormErrorKind.rejected]: the server's reason, if any.
  final String? detail;

  const SiloPasswordFormError(this.kind, {this.detail});

  static SiloPasswordFormError forProblem(SiloNewPasswordProblem problem) => SiloPasswordFormError(switch (problem) {
    SiloNewPasswordProblem.empty => SiloPasswordFormErrorKind.enterNewPassword,
    SiloNewPasswordProblem.mismatch => SiloPasswordFormErrorKind.mismatch,
    SiloNewPasswordProblem.tooShort => SiloPasswordFormErrorKind.tooShort,
    SiloNewPasswordProblem.tooLong => SiloPasswordFormErrorKind.tooLong,
  });

  static SiloPasswordFormError forResult(SiloPasswordChangeResult result) => switch (result) {
    SiloPasswordChangeRefused(:final refusal, :final detail) => SiloPasswordFormError(switch (refusal) {
      SiloPasswordChangeRefusal.wrongCurrentPassword => SiloPasswordFormErrorKind.wrongTemporaryPassword,
      SiloPasswordChangeRefusal.rejected => SiloPasswordFormErrorKind.rejected,
      SiloPasswordChangeRefusal.rateLimited => SiloPasswordFormErrorKind.rateLimited,
      SiloPasswordChangeRefusal.notPasswordAccount => SiloPasswordFormErrorKind.notPasswordAccount,
      SiloPasswordChangeRefusal.notAllowed => SiloPasswordFormErrorKind.notAllowed,
      SiloPasswordChangeRefusal.other => SiloPasswordFormErrorKind.failed,
    }, detail: detail),
    _ => const SiloPasswordFormError(SiloPasswordFormErrorKind.failed),
  };

  @override
  bool operator ==(Object other) => other is SiloPasswordFormError && other.kind == kind && other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, detail);

  @override
  String toString() => 'SiloPasswordFormError($kind)';
}

@immutable
class SiloPasswordChangeState {
  final SiloPasswordChangePhase phase;
  final SiloPasswordFormError? error;

  /// Bumped on each failed attempt, so a repeated error is announced again.
  final int errorCount;

  /// The account's username, once read.
  final String? accountName;
  final SiloPasswordRequirements requirements;

  /// The session no longer carries the restriction: continue to profiles.
  final bool finished;

  const SiloPasswordChangeState({
    this.phase = SiloPasswordChangePhase.editing,
    this.error,
    this.errorCount = 0,
    this.accountName,
    this.requirements = SiloPasswordRequirements.serverDefault,
    this.finished = false,
  });

  bool get isBusy =>
      phase == SiloPasswordChangePhase.saving ||
      phase == SiloPasswordChangePhase.refreshing ||
      phase == SiloPasswordChangePhase.checking;

  /// Whether the form (fields and Save) shows, rather than an outcome.
  bool get showsForm => phase == SiloPasswordChangePhase.editing || phase == SiloPasswordChangePhase.saving;

  SiloPasswordChangeState copyWith({
    SiloPasswordChangePhase? phase,
    SiloPasswordFormError? error,
    bool clearError = false,
    int? errorCount,
    String? accountName,
    SiloPasswordRequirements? requirements,
    bool? finished,
  }) => SiloPasswordChangeState(
    phase: phase ?? this.phase,
    error: clearError ? null : error ?? this.error,
    errorCount: errorCount ?? this.errorCount,
    accountName: accountName ?? this.accountName,
    requirements: requirements ?? this.requirements,
    finished: finished ?? this.finished,
  );
}

/// "Choose a new password": the only thing a session holding a temporary
/// password can do. The account replaces the password an admin set, the
/// session is refreshed so the server lifts its restriction, and sign-in
/// continues to the profiles. Port of Silo Android's `PasswordChangeViewModel`.
class SiloPasswordChangeController extends ValueNotifier<SiloPasswordChangeState> {
  SiloPasswordChangeController(this._account) : super(const SiloPasswordChangeState());

  final SiloTemporaryPasswordAccount _account;
  bool _disposed = false;

  void _set(SiloPasswordChangeState next) {
    if (!_disposed) value = next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Reads the account and the server's limits. An account that no longer
  /// holds a temporary password already changed it (the refresh never
  /// finished, then the screen was opened again): only the session still
  /// carries the restriction, so it is refreshed instead of asking for a
  /// temporary password that no longer works.
  Future<void> load() async {
    final (account, requirements) = await (_orNull(_account.readAccount), _orNull(_account.passwordRequirements)).wait;
    _set(
      value.copyWith(
        accountName: account?.username,
        requirements: requirements ?? SiloPasswordRequirements.serverDefault,
      ),
    );
    if (account?.passwordChangeRequired != false || value.phase != SiloPasswordChangePhase.editing) return;
    _set(value.copyWith(phase: SiloPasswordChangePhase.refreshing));
    await _continueSignIn();
  }

  /// "Save password".
  Future<void> submit({required String current, required String newPassword, required String confirmation}) async {
    if (value.phase != SiloPasswordChangePhase.editing) return;
    final problem = value.requirements.problem(newPassword, confirmation);
    final invalid = current.isEmpty
        ? const SiloPasswordFormError(SiloPasswordFormErrorKind.enterTemporaryPassword)
        : problem == null
        ? null
        : SiloPasswordFormError.forProblem(problem);
    if (invalid != null) {
      _fail(invalid);
      return;
    }
    _set(value.copyWith(phase: SiloPasswordChangePhase.saving, clearError: true));
    // A call that throws is an unknown outcome, like a lost answer.
    final result =
        await _orNull(() => _account.changePassword(current, newPassword)) ?? const SiloPasswordChangeUnknown();
    if (_disposed) return;
    if (result is! SiloPasswordChanged) {
      // A lost answer can hide a change the server saved, and sending the
      // temporary password again would then fail as incorrect: the account
      // says whether it still holds the temporary password. A 4xx is the
      // server's own refusal, so nothing changed and there is nothing to check.
      final remains = result is SiloPasswordChangeRefused ? true : await _temporaryPasswordRemains();
      if (_disposed) return;
      switch (remains) {
        case true:
          _set(value.copyWith(phase: SiloPasswordChangePhase.editing));
          _fail(SiloPasswordFormError.forResult(result));
          return;
        case null:
          _set(value.copyWith(phase: SiloPasswordChangePhase.unconfirmed));
          return;
        case false:
          break;
      }
    }
    _set(value.copyWith(phase: SiloPasswordChangePhase.refreshing, clearError: true));
    await _continueSignIn();
  }

  /// Try again when the change's outcome is unknown: reads the account, never resends.
  Future<void> confirmChange() async {
    if (value.phase != SiloPasswordChangePhase.unconfirmed) return;
    _set(value.copyWith(phase: SiloPasswordChangePhase.checking));
    final remains = await _temporaryPasswordRemains();
    if (_disposed) return;
    switch (remains) {
      case true:
        _set(value.copyWith(phase: SiloPasswordChangePhase.editing));
        _fail(const SiloPasswordFormError(SiloPasswordFormErrorKind.notChanged));
      case null:
        _set(value.copyWith(phase: SiloPasswordChangePhase.unconfirmed));
      case false:
        _set(value.copyWith(phase: SiloPasswordChangePhase.refreshing));
        await _continueSignIn();
    }
  }

  /// Try again after the password changed but the refresh failed: refreshes only.
  Future<void> retryRefresh() async {
    if (value.phase != SiloPasswordChangePhase.refreshFailed) return;
    _set(value.copyWith(phase: SiloPasswordChangePhase.refreshing));
    await _continueSignIn();
  }

  /// Whether the account still holds its temporary password; null when it
  /// cannot be read. A server that does not report it counts as still holding it.
  Future<bool?> _temporaryPasswordRemains() async {
    final account = await _orNull(_account.readAccount);
    if (account == null) return null;
    return account.passwordChangeRequired ?? true;
  }

  Future<void> _continueSignIn() async {
    final refreshed = await _orNull(_account.refreshSessionAfterPasswordChange) ?? false;
    if (_disposed) return;
    _set(refreshed ? value.copyWith(finished: true) : value.copyWith(phase: SiloPasswordChangePhase.refreshFailed));
  }

  void _fail(SiloPasswordFormError error) => _set(value.copyWith(error: error, errorCount: value.errorCount + 1));

  /// [call]'s answer, or null when it threw: each caller treats null as its
  /// unknown outcome.
  static Future<T?> _orNull<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      appLogger.d('Silo temporary password: call failed', error: e.runtimeType);
      return null;
    }
  }
}
