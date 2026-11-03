import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';

const siloTestHeaders = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

const siloTestServer = SiloServerInfo(
  baseUrl: 'https://silo.example.com',
  serverId: 'srv-1',
  serverName: 'Home Silo',
  deviceLoginAvailable: true,
);

http.Response siloJson(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response siloProblem(int status, String detail) => http.Response(
  jsonEncode({'type': 'about:blank', 'title': 'Problem', 'status': status, 'detail': detail}),
  status,
  headers: {'content-type': 'application/problem+json'},
);

/// A Silo v2 problem whose `type` ends in [code], with optional `errors[]`.
http.Response siloCodedProblem(int status, String code, {List<Map<String, Object?>>? errors, String detail = 'd'}) =>
    http.Response(
      jsonEncode({
        'type': 'https://siloserver.org/docs/api/v2/problems/$code',
        'title': 'Problem',
        'status': status,
        'detail': detail,
        'errors': ?errors,
      }),
      status,
      headers: {'content-type': 'application/problem+json'},
    );

/// The refusal a session holding a temporary password gets (Silo Android #790).
http.Response siloPasswordChangeRequired() =>
    siloCodedProblem(403, 'password_change_required', detail: 'Change the password with POST /api/v2/account/password');

/// A scripted Silo server for the sign-in calls. Device codes are numbered
/// (`dev-1`, `dev-2`, …); [pollAnswer] decides each poll's answer.
class FakeSiloAuthServer {
  FakeSiloAuthServer({this.expiresIn = 900, this.interval = 5});

  final int expiresIn;
  final int interval;

  /// Every request, decoded path first.
  final List<http.Request> requests = [];

  int _codes = 0;

  /// Answers a poll for `device_code`; defaults to pending.
  http.Response Function(String deviceCode) pollAnswer = (_) => siloJson({'status': 'pending', 'opened': false});

  /// Answers `/auth/device/start`; defaults to a fresh code.
  http.Response Function()? startAnswer;

  /// Answers `GET /system/identity`; defaults to `srv-1`.
  http.Response Function()? identityAnswer;

  /// Answers `/profiles/{id}/verify-pin`.
  http.Response Function(String pin) verifyPinAnswer = (_) => siloJson({'valid': false});

  List<Map<String, dynamic>> profiles = [
    {'id': 'p-owner', 'name': 'Laura', 'has_pin': false, 'is_primary': true},
    {'id': 'p-kids', 'name': 'Kids', 'has_pin': true, 'is_child': true},
  ];

  /// Temporary passwords (Silo Android #790). While [temporaryPassword] is
  /// set, `/account/me` says `password_change_required: true`, and every
  /// access token issued meanwhile is refused by `/profiles` with 403
  /// `password_change_required` until a refresh replaces it after the change.
  bool temporaryPassword = false;

  /// The temporary password `POST /account/password` accepts.
  String temporaryPasswordValue = 'temp-pass';

  /// Access tokens the server still restricts.
  final Set<String> restrictedTokens = {};

  /// Answers `GET /account/password/capability`.
  http.Response Function() passwordCapabilityAnswer = () =>
      siloJson({'state': 'available', 'allowed': true, 'minimum_password_length': 10, 'maximum_password_bytes': 72});

  /// Answers `POST /account/password`; defaults to Silo's rules (204, or a
  /// 422 naming `body.current_password`).
  http.Response Function(Map<String, dynamic> body)? passwordChangeAnswer;

  /// Answers `GET /account/me`; defaults to the account.
  http.Response Function()? accountAnswer;

  /// Answers `POST /auth/refresh`; defaults to a rotated pair.
  http.Response Function()? refreshAnswer;

  int _refreshes = 0;

  String? _bearer(http.Request request) {
    final header = request.headers['Authorization'] ?? request.headers['authorization'];
    return header != null && header.startsWith('Bearer ') ? header.substring(7) : null;
  }

  /// Marks a newly issued access token restricted while the password is temporary.
  void _issued(String accessToken) {
    if (temporaryPassword) restrictedTokens.add(accessToken);
  }

  List<String> paths() => requests.map((r) => Uri.decodeComponent(r.url.path)).toList();

  List<String> bodiesFor(String path) =>
      requests.where((r) => Uri.decodeComponent(r.url.path) == path).map((r) => r.body).toList();

  int countOf(String path) => paths().where((p) => p == path).length;

  static http.Response approved({String? profileId, String? profileToken}) => siloJson({
    'status': 'approved',
    'tokens': {
      'access_token': 'acc',
      'refresh_token': 'ref',
      'expires_in': 3600,
      'user': {'id': '1', 'username': 'laura', 'role': 'user'},
    },
    'profile_id': profileId ?? '',
    'profile_token': profileToken ?? '',
  });

  http.Client client() => MockClient((request) async {
    requests.add(request);
    final path = Uri.decodeComponent(request.url.path);
    final restricted = restrictedTokens.contains(_bearer(request));
    switch (path) {
      case '/api/v2/auth/login':
        _issued('acc');
        return siloJson({
          'access_token': 'acc',
          'refresh_token': 'ref',
          'expires_in': 3600,
          'user': {
            'id': '1',
            'username': 'laura',
            'role': 'user',
            'password_change_required': ?(temporaryPassword ? true : null),
          },
        });
      case '/api/v2/auth/refresh':
        final custom = refreshAnswer;
        if (custom != null) return custom();
        final n = ++_refreshes;
        _issued('acc-$n');
        return siloJson({'access_token': 'acc-$n', 'refresh_token': 'ref-$n', 'expires_in': 3600});
      case '/api/v2/account/password/capability':
        return passwordCapabilityAnswer();
      case '/api/v2/account/password':
        final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
        final custom = passwordChangeAnswer;
        if (custom != null) return custom(body);
        if (body['current_password'] != temporaryPasswordValue) {
          return siloCodedProblem(
            422,
            'validation_failed',
            errors: [
              {'location': 'body.current_password', 'code': 'invalid', 'detail': 'incorrect'},
            ],
          );
        }
        temporaryPassword = false;
        return http.Response('', 204);
      case '/api/v2/system/info':
        return siloJson({'api_major': 2, 'server_version': '1.2.3'});
      case '/api/v2/system/identity':
        return identityAnswer?.call() ?? siloJson({'server_id': 'srv-1'});
      case '/api/v2/theme/branding':
        return siloJson({'server_name': 'Home Silo'});
      case '/api/v2/auth/device/capability':
        return siloJson({'state': 'available', 'cancel': true});
      case '/api/v2/auth/providers':
        return siloJson({'password_login': true, 'items': []});
      case '/api/v2/auth/device/start':
        final custom = startAnswer;
        if (custom != null) return custom();
        final n = ++_codes;
        return siloJson({
          'device_code': 'dev-$n',
          'user_code': '4821773$n',
          'match_code': 'brave-otter-$n',
          'verification_uri': 'https://silo.example.com/activate',
          'verification_uri_complete': 'https://silo.example.com/activate?code=4821773$n',
          'expires_in': expiresIn,
          'interval': interval,
        }, 201);
      case '/api/v2/auth/device/poll':
        final code = (jsonDecode(request.body) as Map)['device_code'] as String;
        return pollAnswer(code);
      case '/api/v2/auth/device/cancel':
        return siloJson({'status': 'canceled'});
      case '/api/v2/auth/logout':
        return http.Response('', 204);
      case '/api/v2/account/me':
        final custom = accountAnswer;
        if (custom != null) return custom();
        return siloJson({'id': '1', 'username': 'laura', 'password_change_required': temporaryPassword});
      case '/api/v2/profiles':
        if (restricted) return siloPasswordChangeRequired();
        return siloJson({'items': profiles});
    }
    if (restricted) return siloPasswordChangeRequired();
    if (path.startsWith('/api/v2/profiles/') && path.endsWith('/verify-pin')) {
      final pin = (jsonDecode(request.body) as Map)['pin'] as String;
      return verifyPinAnswer(pin);
    }
    return http.Response('404 page not found', 404);
  });

  SiloAuthService service() => SiloAuthService(deviceId: 'dev-1', clientFactory: client, headers: siloTestHeaders);
}
