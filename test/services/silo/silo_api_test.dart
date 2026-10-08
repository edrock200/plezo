import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';

SiloDeviceHeaders _headers(String family) =>
    SiloDeviceHeaders(deviceId: 'd', deviceName: 'n', platform: 'android', clientFamily: family, clientVersion: '1');

void main() {
  group('server address candidates', () {
    test('a bare host tries https, http, then Silo\'s default port', () {
      expect(SiloAuthService.candidatesFor('Silo.Local'), [
        'https://silo.local',
        'http://silo.local',
        'http://silo.local:8090',
      ]);
    });

    test('an explicit port or scheme is kept as typed', () {
      expect(SiloAuthService.candidatesFor('silo.local:9000/prefix/'), [
        'https://silo.local:9000/prefix',
        'http://silo.local:9000/prefix',
      ]);
      expect(SiloAuthService.candidatesFor('http://10.0.0.5:8090'), ['http://10.0.0.5:8090']);
    });
  });

  group('form factor', () {
    test('tablets report their own client family but play as mobile', () {
      expect(_headers('tablet').toHeaders()['X-Silo-Client-Family'], 'tablet');
      expect(_headers('tablet').formFactor.playbackFormFactor, 'mobile');
      expect(_headers('mobile').formFactor.playbackFormFactor, 'mobile');
      expect(_headers('tv').formFactor.playbackFormFactor, 'tv');
      expect(_headers('desktop').formFactor.playbackFormFactor, 'desktop');
    });
  });

  test('problem codes come from the last segment of the type URI', () {
    expect(siloProblemCode({'type': 'https://siloserver.org/docs/api/v2/problems/session_expired'}), 'session_expired');
    expect(siloProblemCode('not json'), isNull);
  });
}
