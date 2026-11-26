import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_catchup.dart';

void main() {
  final start = DateTime.utc(2026, 11, 26, 18, 30, 5);
  final startEpoch = start.millisecondsSinceEpoch ~/ 1000;
  final now = DateTime.utc(2026, 11, 26, 19, 0);
  final nowEpoch = now.millisecondsSinceEpoch ~/ 1000;
  const duration = Duration(minutes: 45);

  String? build(IptvCatchupMode mode, String url, {String? source}) => IptvCatchup.build(
    mode: mode,
    channelUrl: url,
    source: source,
    start: start,
    duration: duration,
    now: now,
    catchupId: 'abc',
  );

  test('modes parse from playlist values', () {
    expect(IptvCatchupMode.parse('default'), IptvCatchupMode.defaultMode);
    expect(IptvCatchupMode.parse('APPEND'), IptvCatchupMode.append);
    expect(IptvCatchupMode.parse('shift'), IptvCatchupMode.shift);
    expect(IptvCatchupMode.parse('timeshift'), IptvCatchupMode.shift);
    expect(IptvCatchupMode.parse('flussonic-hls'), IptvCatchupMode.flussonic);
    expect(IptvCatchupMode.parse('fs'), IptvCatchupMode.flussonic);
    expect(IptvCatchupMode.parse('xc'), IptvCatchupMode.xtream);
    expect(IptvCatchupMode.parse('vod'), IptvCatchupMode.none);
    expect(IptvCatchupMode.parse(null), IptvCatchupMode.none);
  });

  test('default: a whole template with every placeholder', () {
    final url = build(
      IptvCatchupMode.defaultMode,
      'http://s.example/live/1.m3u8',
      source:
          'http://a.example/arc/{Y}/{m}/{d}/{H}-{M}-{S}.ts?s={utc}&e={utcend}&now={lutc}&d={duration}&dm={duration:60}'
          '&o={offset}&f={utc:Y-m-d}&b=\${start}&x={(b)YmdHMS}&z={(e)YmdHM}&id={catchup-id}',
    );
    expect(
      url,
      'http://a.example/arc/2026/11/26/18-30-05.ts?s=$startEpoch&e=${startEpoch + 2700}&now=$nowEpoch&d=2700&dm=45'
      '&o=${nowEpoch - startEpoch}&f=2026-11-26&b=$startEpoch&x=20261126183005&z=202611261915&id=abc',
    );
  });

  test('default: a relative source rides on the channel URL', () {
    expect(
      build(IptvCatchupMode.defaultMode, 'http://s.example/1.m3u8?token=t', source: 'utc={utc}'),
      'http://s.example/1.m3u8?token=t&utc=$startEpoch',
    );
    expect(build(IptvCatchupMode.defaultMode, 'http://s.example/1', source: null), isNull);
  });

  test('append: the source is appended as is', () {
    expect(
      build(IptvCatchupMode.append, 'http://s.example/1.m3u8', source: '?start={utc}&dur={duration}'),
      'http://s.example/1.m3u8?start=$startEpoch&dur=2700',
    );
  });

  test('shift: utc and lutc are appended', () {
    expect(
      build(IptvCatchupMode.shift, 'http://s.example/1.ts'),
      'http://s.example/1.ts?utc=$startEpoch&lutc=$nowEpoch',
    );
    expect(
      build(IptvCatchupMode.shift, 'http://s.example/1.ts?a=1'),
      'http://s.example/1.ts?a=1&utc=$startEpoch&lutc=$nowEpoch',
    );
  });

  test('flussonic: HLS and MPEG-TS archive paths', () {
    expect(
      build(IptvCatchupMode.flussonic, 'http://f.example/ch1/index.m3u8?token=x'),
      'http://f.example/ch1/index-$startEpoch-2700.m3u8?token=x',
    );
    expect(
      build(IptvCatchupMode.flussonic, 'http://f.example/ch1/video.m3u8'),
      'http://f.example/ch1/video-$startEpoch-2700.m3u8',
    );
    expect(
      build(IptvCatchupMode.flussonic, 'http://f.example/ch1/mpegts?token=x'),
      'http://f.example/ch1/timeshift_abs-$startEpoch.ts?token=x',
    );
  });

  test('xc: an Xtream channel address becomes the timeshift route', () {
    expect(
      build(IptvCatchupMode.xtream, 'http://x.example:8080/live/user/pass/123.ts'),
      'http://x.example:8080/timeshift/user/pass/45/2026-11-26:18-30/123.ts',
    );
    expect(
      build(IptvCatchupMode.xtream, 'http://x.example/user/pass/123'),
      'http://x.example/timeshift/user/pass/45/2026-11-26:18-30/123.ts',
    );
    expect(build(IptvCatchupMode.xtream, 'http://x.example/123.ts'), isNull);
  });

  test('Xtream timeshift: server clock offset, the php route, login escaped', () {
    expect(
      IptvCatchup.xtreamTimeshiftUrl(
        base: 'http://x.example',
        username: 'u@x',
        password: 'p/w',
        streamId: '9',
        start: start,
        duration: const Duration(minutes: 30, seconds: 1),
        serverOffset: const Duration(hours: 1),
      ),
      'http://x.example/timeshift/u%40x/p%2Fw/31/2026-11-26:19-30/9.ts',
    );
    expect(
      IptvCatchup.xtreamTimeshiftUrl(
        base: 'http://x.example',
        username: 'u',
        password: 'p',
        streamId: '9',
        start: start,
        duration: duration,
        phpRoute: true,
      ),
      'http://x.example/streaming/timeshift.php?username=u&password=p&stream=9&start=2026-11-26:18-30&duration=45',
    );
  });

  test('none builds nothing', () {
    expect(build(IptvCatchupMode.none, 'http://s.example/1.ts'), isNull);
  });
}
