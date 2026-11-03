import 'dart:async';

import 'package:flutter/foundation.dart';

import '../silo_auth_service.dart';
import '../silo_device_sign_in.dart';
import 'silo_pairing_protocol.dart';
import 'silo_pairing_receiver.dart';

/// Glue between the sign-in screen's device-code flow ([SiloDeviceSignIn])
/// and a phone's pairing attempt: which code to send, and how the code ended.

SiloPairingCode siloPairingCodeOf(SiloDeviceCode code) =>
    SiloPairingCode(deviceCode: code.deviceCode, userCode: code.userCode, matchCode: code.matchCode);

bool _showsCode(SiloDeviceSignInStatus status) => switch (status) {
  SiloDeviceSignInStatus.waiting ||
  SiloDeviceSignInStatus.opened ||
  SiloDeviceSignInStatus.newCode ||
  SiloDeviceSignInStatus.unreachable ||
  SiloDeviceSignInStatus.tooManyRequests => true,
  _ => false,
};

/// The first live code [state] shows. Throws [SiloPairingAttemptFailure] when
/// the flow settles without one (a server without device sign-in, one that
/// needs an update, or one that stays unreachable), or after [timeout].
Future<SiloPairingCode> siloPairingFirstCode(
  ValueListenable<SiloDeviceSignInState> state, {
  Duration timeout = const Duration(seconds: 60),
}) {
  final completer = Completer<SiloPairingCode>();
  void check() {
    if (completer.isCompleted) return;
    final value = state.value;
    final code = value.code;
    if (code != null && _showsCode(value.status)) {
      completer.complete(siloPairingCodeOf(code));
      return;
    }
    final failure = switch (value.status) {
      SiloDeviceSignInStatus.updateRequired => SiloPairingFailureCode.updateRequired,
      // Still retrying, but nothing to show: the address does not answer from here.
      SiloDeviceSignInStatus.unreachable => SiloPairingFailureCode.unreachable,
      SiloDeviceSignInStatus.noDeviceSignIn ||
      SiloDeviceSignInStatus.failed ||
      SiloDeviceSignInStatus.denied ||
      SiloDeviceSignInStatus.paused ||
      SiloDeviceSignInStatus.tooManyRequests => SiloPairingFailureCode.authFailed,
      _ => null,
    };
    if (failure != null) completer.completeError(SiloPairingAttemptFailure(failure));
  }

  state.addListener(check);
  check();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(const SiloPairingAttemptFailure(SiloPairingFailureCode.unreachable));
    }
  });
  return completer.future.whenComplete(() {
    timer.cancel();
    state.removeListener(check);
  });
}

/// How the request behind [deviceCode] ended: null once [signedIn] reports
/// the approval became a session, else the wire failure. The code being
/// replaced (expired on the server, renewed) is `expired`, as on Silo's TVs;
/// [signedIn] completing false (the flow was left or could not finish) is
/// `expired` before an approval and `auth_failed` after one.
Future<SiloPairingFailureCode?> siloPairingOutcome(
  ValueListenable<SiloDeviceSignInState> state,
  String deviceCode,
  Future<bool> signedIn,
) {
  final completer = Completer<SiloPairingFailureCode?>();
  var approved = false;
  void check() {
    if (completer.isCompleted) return;
    final value = state.value;
    switch (value.status) {
      case SiloDeviceSignInStatus.approved:
        approved = true;
      case SiloDeviceSignInStatus.denied:
        completer.complete(SiloPairingFailureCode.denied);
      case SiloDeviceSignInStatus.paused:
        completer.complete(SiloPairingFailureCode.expired);
      case SiloDeviceSignInStatus.updateRequired:
        completer.complete(SiloPairingFailureCode.updateRequired);
      case SiloDeviceSignInStatus.failed || SiloDeviceSignInStatus.noDeviceSignIn:
        completer.complete(SiloPairingFailureCode.authFailed);
      case SiloDeviceSignInStatus.gettingCode:
        completer.complete(SiloPairingFailureCode.expired);
      case _:
        final code = value.code;
        if (code != null && code.deviceCode != deviceCode) completer.complete(SiloPairingFailureCode.expired);
    }
  }

  state.addListener(check);
  check();
  unawaited(
    signedIn.then(
      (ok) {
        if (completer.isCompleted) return;
        if (ok) {
          completer.complete(null);
        } else {
          completer.complete(approved ? SiloPairingFailureCode.authFailed : SiloPairingFailureCode.expired);
        }
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete(SiloPairingFailureCode.authFailed);
      },
    ),
  );
  return completer.future.whenComplete(() => state.removeListener(check));
}
