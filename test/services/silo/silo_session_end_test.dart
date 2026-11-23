import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/silo/silo_catalog_strings.dart';
import 'package:plezy/services/silo/silo_playback_caps.dart';
import 'package:plezy/services/silo/silo_session_end.dart';

Map<String, Object?> _problem(String code) => {
  'type': 'https://siloserver.org/docs/api/v2/problems/$code',
  'title': code,
  'status': 410,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SiloCatalogStrings.debugSetTables());

  group('SiloSessionEnd.of', () {
    test('names the administrator end and the paused timeout from a 410 problem', () {
      expect(SiloSessionEnd.of(410, _problem('playback_session_ended')), SiloSessionEnd.admin);
      expect(SiloSessionEnd.of(410, _problem('playback_session_paused_timeout')), SiloSessionEnd.pausedTimeout);
      // A bare `code`, as some answers carry it.
      expect(SiloSessionEnd.of(410, {'code': 'playback_session_paused_timeout'}), SiloSessionEnd.pausedTimeout);
    });

    test('anything else is not an end for good', () {
      expect(SiloSessionEnd.of(404, _problem('playback_session_paused_timeout')), isNull);
      expect(SiloSessionEnd.of(410, _problem('gone')), isNull);
      expect(SiloSessionEnd.of(410, null), isNull);
      expect(SiloSessionEnd.of(200, const {}), isNull);
    });
  });

  group('notice', () {
    test('the administrator end keeps its wording', () {
      expect(SiloSessionEnd.admin.notice, t.messages.playbackSessionEndedByServer);
    });

    test('the paused timeout says the pause ran too long, without a catalog loaded', () {
      expect(SiloSessionEnd.pausedTimeout.notice, 'Playback stopped because it was paused for too long.');
      expect(SiloSessionEnd.pausedTimeout.notice, isNot(t.messages.playbackSessionEndedByServer));
    });

    test("the paused timeout uses Silo's catalog text in the app's language", () async {
      await SiloCatalogStrings.load(AppLocale.de);
      expect(SiloSessionEnd.pausedTimeout.notice, 'Die Wiedergabe wurde beendet, weil sie zu lange pausiert war.');
    });
  });

  group('client features', () {
    test('a video start lists paused_timeout_v1 next to the base features', () {
      expect(SiloPlaybackCaps.clientFeaturesFor(pausedTimeout: true), [
        ...SiloPlaybackCaps.clientFeatures,
        'paused_timeout_v1',
      ]);
    });

    test('a start whose player cannot leave on it does not', () {
      expect(SiloPlaybackCaps.clientFeaturesFor(pausedTimeout: false), SiloPlaybackCaps.clientFeatures);
      expect(SiloPlaybackCaps.clientFeatures, isNot(contains('paused_timeout_v1')));
    });
  });
}
