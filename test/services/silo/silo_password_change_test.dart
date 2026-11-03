import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';
import 'package:plezy/services/silo/silo_password_change.dart';
import 'package:plezy/utils/error_message_utils.dart';

import '../../test_helpers/silo_auth_fake.dart';

/// A scripted [SiloTemporaryPasswordAccount] that records its calls.
class _FakeAccount implements SiloTemporaryPasswordAccount {
  /// Each `readAccount` answer in turn (the last repeats); an [Exception] is thrown.
  List<Object> accounts = [const SiloAccount(id: '1', username: 'laura', passwordChangeRequired: true)];
  SiloPasswordRequirements requirements = const SiloPasswordRequirements(minimumLength: 10, maximumBytes: 72);
  FutureOr<SiloPasswordChangeResult> Function(String current, String next) change = (_, _) =>
      const SiloPasswordChanged();
  List<bool> refreshes = [true];

  final List<String> calls = [];
  int _reads = 0;
  int _refreshCount = 0;

  int count(String call) => calls.where((c) => c == call).length;

  @override
  Future<SiloAccount> readAccount() async {
    calls.add('read');
    final answer = accounts[_reads < accounts.length ? _reads : accounts.length - 1];
    _reads++;
    if (answer is Exception) throw answer;
    return answer as SiloAccount;
  }

  @override
  Future<SiloPasswordRequirements> passwordRequirements() async {
    calls.add('requirements');
    return requirements;
  }

  @override
  Future<SiloPasswordChangeResult> changePassword(String current, String next) async {
    calls.add('change');
    return change(current, next);
  }

  @override
  Future<bool> refreshSessionAfterPasswordChange() async {
    calls.add('refresh');
    final answer = refreshes[_refreshCount < refreshes.length ? _refreshCount : refreshes.length - 1];
    _refreshCount++;
    return answer;
  }
}

const _changed = SiloAccount(id: '1', username: 'laura', passwordChangeRequired: false);
final _unreadable = MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'down');

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  group('wire', () {
    test('account/me carries password_change_required, absent from older servers', () {
      expect(SiloAccount.fromJson({'id': '1', 'password_change_required': true})!.passwordChangeRequired, isTrue);
      expect(SiloAccount.fromJson({'id': '1', 'password_change_required': false})!.passwordChangeRequired, isFalse);
      expect(SiloAccount.fromJson({'id': '1'})!.passwordChangeRequired, isNull);
    });

    test('the capability gives the limits; missing or non-positive ones keep the defaults', () {
      final capability = SiloPasswordCapability.fromJson({
        'state': 'available',
        'allowed': true,
        'minimum_password_length': 12,
        'maximum_password_bytes': 64,
      })!;
      expect(capability.allowed, isTrue);
      expect(
        SiloPasswordRequirements.from(capability),
        const SiloPasswordRequirements(minimumLength: 12, maximumBytes: 64),
      );
      final sparse = SiloPasswordCapability.fromJson({'state': 'unavailable', 'minimum_password_length': 0})!;
      expect(sparse.allowed, isNull);
      expect(SiloPasswordRequirements.from(sparse), SiloPasswordRequirements.serverDefault);
      expect(
        SiloPasswordRequirements.serverDefault,
        const SiloPasswordRequirements(minimumLength: 8, maximumBytes: 72),
      );
      expect(SiloPasswordCapability.fromJson({'allowed': true}), isNull);
    });

    test('a new password is checked in code points and UTF-8 bytes, as the server does', () {
      const rules = SiloPasswordRequirements(minimumLength: 8, maximumBytes: 72);
      expect(rules.problem('', ''), SiloNewPasswordProblem.empty);
      expect(rules.problem('long-enough', 'long-enougH'), SiloNewPasswordProblem.mismatch);
      expect(rules.problem('short', 'short'), SiloNewPasswordProblem.tooShort);
      // Seven emoji are 14 UTF-16 units but 7 characters.
      final seven = '😀' * 7;
      expect(rules.problem(seven, seven), SiloNewPasswordProblem.tooShort);
      final eight = '😀' * 8;
      expect(rules.problem(eight, eight), isNull);
      // 40 characters, 80 bytes.
      final wide = 'é' * 40;
      expect(rules.problem(wide, wide), SiloNewPasswordProblem.tooLong);
      expect(rules.problem('a-new-password', 'a-new-password'), isNull);
    });

    test('change answers: 204 changed, 4xx refused by kind, anything else unknown', () {
      SiloPasswordChangeResult map(int status, [Object? data]) => SiloPasswordChangeResult.fromResponse(status, data);
      Map<String, Object?> problem(String? location, {String detail = 'Use 12 characters'}) => {
        'type': 'https://siloserver.org/docs/api/v2/problems/validation_failed',
        'status': 422,
        'errors': [
          if (location != null) {'location': location, 'code': 'invalid', 'detail': detail},
        ],
      };

      expect(map(204), isA<SiloPasswordChanged>());
      expect(map(200, {'ok': true}), isA<SiloPasswordChangeUnknown>());
      expect(map(502), isA<SiloPasswordChangeUnknown>());
      expect(
        map(422, problem('body.current_password')),
        isA<SiloPasswordChangeRefused>()
            .having((r) => r.refusal, 'refusal', SiloPasswordChangeRefusal.wrongCurrentPassword)
            .having((r) => r.detail, 'detail', isNull),
      );
      expect(
        map(422, problem('body.new_password')),
        isA<SiloPasswordChangeRefused>()
            .having((r) => r.refusal, 'refusal', SiloPasswordChangeRefusal.rejected)
            .having((r) => r.detail, 'detail', 'Use 12 characters'),
      );
      expect((map(422, problem(null)) as SiloPasswordChangeRefused).detail, isNull);
      expect((map(429) as SiloPasswordChangeRefused).refusal, SiloPasswordChangeRefusal.rateLimited);
      expect((map(409) as SiloPasswordChangeRefused).refusal, SiloPasswordChangeRefusal.notPasswordAccount);
      expect((map(403) as SiloPasswordChangeRefused).refusal, SiloPasswordChangeRefusal.notAllowed);
      expect((map(401) as SiloPasswordChangeRefused).refusal, SiloPasswordChangeRefusal.other);
    });
  });

  group('the refusal elsewhere', () {
    late FakeSiloAuthServer server;
    setUp(() => server = FakeSiloAuthServer()..restrictedTokens.add('acc'));

    SiloApi api() => SiloApi(
      baseUrl: siloTestServer.baseUrl,
      device: siloTestHeaders,
      tokens: const SiloTokens(accessToken: 'acc', refreshToken: 'ref'),
      profileId: 'p-owner',
      client: server.client(),
    );

    test('a 403 password_change_required throws with a plain message', () async {
      final error = await api()
          .getJson('/api/v2/profiles', profile: false)
          .then<Object?>((_) => null, onError: (e) => e);
      expect(error, isA<SiloPasswordChangeRequiredException>().having((e) => e.statusCode, 'statusCode', 403));
      final refusal = error! as SiloPasswordChangeRequiredException;
      expect(refusal.display, t.errors.siloTemporaryPassword);
      expect(refusal.display, isNot(contains('POST')), reason: "the server's protocol detail is never shown");
      expect(localizedLoadErrorText(refusal, context: 'libraries'), t.errors.siloTemporaryPassword);
      expect(localizedErrorReason(refusal), t.errors.reasonSiloTemporaryPassword);
      expect(classifyPlaybackFailure(refusal).message, t.errors.siloTemporaryPassword);
    });

    test('also from raw requests, and only for that problem', () async {
      await expectLater(
        api().request('GET', '/api/v2/catalog/items/x'),
        throwsA(isA<SiloPasswordChangeRequiredException>()),
      );
      expect(isSiloPasswordChangeRequired(403, {'type': 'https://x/problems/password_change_required'}), isTrue);
      expect(isSiloPasswordChangeRequired(403, {'type': 'https://x/problems/forbidden'}), isFalse);
      expect(isSiloPasswordChangeRequired(401, {'type': 'https://x/problems/password_change_required'}), isFalse);
    });

    test('fetchProfiles hands the refusal to the sign-in screen', () async {
      final signIn = SiloSignIn(
        server: siloTestServer,
        tokens: const SiloTokens(accessToken: 'acc', refreshToken: 'ref'),
        account: const SiloAccount(id: '1', username: 'laura'),
        deviceId: 'dev-1',
      );
      await expectLater(server.service().fetchProfiles(signIn), throwsA(isA<SiloPasswordChangeRequiredException>()));
    });
  });

  group('SiloTemporaryPasswordSession', () {
    late FakeSiloAuthServer server;
    late List<SiloTokens> rotated;
    late SiloTemporaryPasswordSession session;

    setUp(() async {
      server = FakeSiloAuthServer()
        ..temporaryPassword = true
        ..restrictedTokens.add('acc');
      rotated = [];
      final signIn = SiloSignIn(
        server: siloTestServer,
        tokens: const SiloTokens(accessToken: 'acc', refreshToken: 'ref'),
        account: const SiloAccount(id: '1', username: 'laura'),
        deviceId: 'dev-1',
        presetProfileId: 'p-owner',
      );
      session = await server.service().temporaryPasswordSession(signIn, onTokensRefreshed: rotated.add);
    });
    tearDown(() => session.close());

    http.Request only(String path) => server.requests.singleWhere((r) => Uri.decodeComponent(r.url.path) == path);

    test('reads the account and the limits with no profile declared', () async {
      final account = await session.readAccount();
      expect(account.username, 'laura');
      expect(account.passwordChangeRequired, isTrue);
      expect(await session.passwordRequirements(), const SiloPasswordRequirements(minimumLength: 10, maximumBytes: 72));
      for (final path in ['/api/v2/account/me', '/api/v2/account/password/capability']) {
        expect(only(path).headers['Authorization'], 'Bearer acc');
        expect(only(path).headers.containsKey('X-Profile-Id'), isFalse);
      }
    });

    test('an unreadable capability falls back to the server defaults', () async {
      server.passwordCapabilityAnswer = () => http.Response('404 page not found', 404);
      expect(await session.passwordRequirements(), SiloPasswordRequirements.serverDefault);
    });

    test('sends the change once, account-scoped, with both passwords in the body', () async {
      final result = await session.changePassword('temp-pass', 'a-new-password');
      expect(result, isA<SiloPasswordChanged>());
      final request = only('/api/v2/account/password');
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer acc');
      expect(request.headers.containsKey('X-Profile-Id'), isFalse, reason: 'a declared profile would be refused');
      expect(jsonDecode(request.body), {'current_password': 'temp-pass', 'new_password': 'a-new-password'});
      expect(server.temporaryPassword, isFalse);
    });

    test('a wrong temporary password is a refusal', () async {
      final result = await session.changePassword('nope', 'a-new-password');
      expect(
        result,
        isA<SiloPasswordChangeRefused>().having(
          (r) => r.refusal,
          'refusal',
          SiloPasswordChangeRefusal.wrongCurrentPassword,
        ),
      );
    });

    test('a 401 refreshes the token for the next try but never resends', () async {
      server.passwordChangeAnswer = (_) => siloCodedProblem(401, 'invalid_token');
      final result = await session.changePassword('temp-pass', 'a-new-password');
      expect(result, isA<SiloPasswordChangeRefused>());
      expect(server.countOf('/api/v2/account/password'), 1);
      expect(server.countOf('/api/v2/auth/refresh'), 1);
      expect(rotated.single.accessToken, 'acc-1');
    });

    test('no answer is an unknown outcome', () async {
      server.passwordChangeAnswer = (_) => throw http.ClientException('connection reset');
      expect(await session.changePassword('temp-pass', 'a-new-password'), isA<SiloPasswordChangeUnknown>());
      expect(server.countOf('/api/v2/account/password'), 1);
    });

    test('the forced refresh rotates the pair, reports it and lifts the restriction', () async {
      await session.changePassword('temp-pass', 'a-new-password');
      expect(await session.refreshSessionAfterPasswordChange(), isTrue);
      expect(rotated.single.refreshToken, 'ref-1');
      expect(session.tokens?.accessToken, 'acc-1');
      expect(server.restrictedTokens.contains('acc-1'), isFalse);
    });

    test('a refresh that fails reports false and keeps the session', () async {
      server.refreshAnswer = () => http.Response('bad gateway', 502);
      expect(await session.refreshSessionAfterPasswordChange(), isFalse);
      expect(session.tokens?.accessToken, 'acc');
      expect(rotated, isEmpty);
    });
  });

  group('SiloPasswordChangeController', () {
    late _FakeAccount account;
    late SiloPasswordChangeController controller;

    setUp(() {
      account = _FakeAccount();
      controller = SiloPasswordChangeController(account);
    });
    tearDown(() => controller.dispose());

    Future<void> save({String current = 'temp-pass', String next = 'a-new-password', String? confirmation}) =>
        controller.submit(current: current, newPassword: next, confirmation: confirmation ?? next);

    SiloPasswordChangeState current() => controller.value;

    test('load reads the name and the limits and keeps the form open', () async {
      await controller.load();
      expect(current().accountName, 'laura');
      expect(current().requirements.minimumLength, 10);
      expect(current().phase, SiloPasswordChangePhase.editing);
      expect(account.count('refresh'), 0);
    });

    test('an account that already changed its password goes straight to the refresh', () async {
      account.accounts = [_changed];
      await controller.load();
      expect(account.calls, containsAllInOrder(['read', 'refresh']));
      expect(account.count('change'), 0);
      expect(current().finished, isTrue);
    });

    test('an unreadable account on load keeps the form and the default limits', () async {
      account.accounts = [_unreadable];
      account.requirements = SiloPasswordRequirements.serverDefault;
      await controller.load();
      expect(current().phase, SiloPasswordChangePhase.editing);
      expect(current().accountName, isNull);
      expect(account.count('refresh'), 0);
    });

    test('the form is checked locally before anything is sent', () async {
      await controller.load();
      await save(current: '');
      expect(current().error?.kind, SiloPasswordFormErrorKind.enterTemporaryPassword);
      await save(next: '');
      expect(current().error?.kind, SiloPasswordFormErrorKind.enterNewPassword);
      await save(confirmation: 'something-else');
      expect(current().error?.kind, SiloPasswordFormErrorKind.mismatch);
      expect(account.count('change'), 0);
      await save(next: 'ten-chars!');
      expect(account.count('change'), 1, reason: '10 characters meet the minimum');
    });

    test('a too-short password is refused at the server minimum and bumps the error count', () async {
      await controller.load();
      await save(next: 'nine-char');
      expect(current().error?.kind, SiloPasswordFormErrorKind.tooShort);
      expect(current().errorCount, 1);
      await save(next: 'nine-char');
      expect(current().errorCount, 2, reason: 'a repeated error is announced again');
      expect(account.count('change'), 0);
    });

    test('a change, then the refresh, finishes', () async {
      await controller.load();
      await save();
      expect(account.calls.where((c) => c == 'change' || c == 'refresh'), ['change', 'refresh']);
      expect(current().finished, isTrue);
      expect(current().error, isNull);
    });

    test("the server's refusal stays on the form without reading the account", () async {
      await controller.load();
      final reads = account.count('read');
      account.change = (_, _) => const SiloPasswordChangeRefused(422, SiloPasswordChangeRefusal.wrongCurrentPassword);
      await save();
      expect(current().phase, SiloPasswordChangePhase.editing);
      expect(current().error?.kind, SiloPasswordFormErrorKind.wrongTemporaryPassword);
      expect(account.count('read'), reads);
      expect(account.count('refresh'), 0);

      account.change = (_, _) =>
          const SiloPasswordChangeRefused(422, SiloPasswordChangeRefusal.rejected, detail: 'Too common');
      await save();
      expect(current().error, const SiloPasswordFormError(SiloPasswordFormErrorKind.rejected, detail: 'Too common'));
      account.change = (_, _) => const SiloPasswordChangeRefused(429, SiloPasswordChangeRefusal.rateLimited);
      await save();
      expect(current().error?.kind, SiloPasswordFormErrorKind.rateLimited);
    });

    test('a lost answer with the password still temporary reopens the form', () async {
      await controller.load();
      account.change = (_, _) => const SiloPasswordChangeUnknown();
      await save();
      expect(current().phase, SiloPasswordChangePhase.editing);
      expect(current().error?.kind, SiloPasswordFormErrorKind.failed);
      expect(account.count('refresh'), 0);
    });

    test('a lost answer that the account shows was saved continues to the refresh', () async {
      await controller.load();
      account.accounts = [_changed];
      account.change = (_, _) => const SiloPasswordChangeUnknown();
      await save();
      expect(current().finished, isTrue);
      expect(account.count('change'), 1);
    });

    test('a change that throws counts as a lost answer', () async {
      await controller.load();
      account.accounts = [_changed];
      account.change = (_, _) => throw StateError('boom');
      await save();
      expect(current().finished, isTrue);
    });

    test('an unknown outcome closes the form; Try again reads the account and never resends', () async {
      await controller.load();
      account.accounts = [_unreadable];
      account.change = (_, _) => const SiloPasswordChangeUnknown();
      await save();
      expect(current().phase, SiloPasswordChangePhase.unconfirmed);
      expect(current().showsForm, isFalse);

      // Saving again is ignored while the outcome is unknown.
      await save();
      expect(account.count('change'), 1);

      final pending = controller.confirmChange();
      expect(current().phase, SiloPasswordChangePhase.checking);
      expect(current().isBusy, isTrue);
      await pending;
      expect(current().phase, SiloPasswordChangePhase.unconfirmed);

      account.accounts = [_changed];
      await controller.confirmChange();
      expect(current().finished, isTrue);
      expect(account.count('change'), 1);
    });

    test('Try again that finds the password unchanged reopens the form', () async {
      await controller.load();
      account.accounts = [_unreadable];
      account.change = (_, _) => const SiloPasswordChangeUnknown();
      await save();
      account.accounts = [const SiloAccount(id: '1', username: 'laura')]; // no flag: still temporary
      await controller.confirmChange();
      expect(current().phase, SiloPasswordChangePhase.editing);
      expect(current().error?.kind, SiloPasswordFormErrorKind.notChanged);
    });

    test('a failed refresh keeps the form closed; Try again refreshes only', () async {
      await controller.load();
      account.refreshes = [false, true];
      await save();
      expect(current().phase, SiloPasswordChangePhase.refreshFailed);
      expect(current().finished, isFalse);

      await save();
      expect(account.count('change'), 1, reason: 'the temporary password no longer works');

      await controller.retryRefresh();
      expect(current().finished, isTrue);
      expect(account.count('change'), 1);
      expect(account.count('refresh'), 2);
    });

    test('Try again in the wrong phase does nothing', () async {
      await controller.load();
      await controller.retryRefresh();
      await controller.confirmChange();
      expect(account.count('refresh'), 0);
      expect(current().phase, SiloPasswordChangePhase.editing);
    });
  });
}
