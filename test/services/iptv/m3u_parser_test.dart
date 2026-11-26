import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';

Future<({M3uHeader header, List<M3uEntry> entries})> parse(String text) async {
  final entries = <M3uEntry>[];
  final header = await M3uStreamParser.parse(M3uStreamParser.linesOf(Stream.value(utf8.encode(text))), entries.add);
  return (header: header, entries: entries);
}

void main() {
  test('reads the header guide addresses and catch-up defaults', () async {
    final result = await parse(
      '#EXTM3U url-tvg="http://a.example/epg.xml,http://b.example/epg.xml.gz" x-tvg-url="http://c.example/g.xml" '
      'catchup="append" catchup-source="?utc={utc}" catchup-days="7" tvg-shift="-1.5"\n'
      '#EXTINF:-1,One\nhttp://s.example/1\n',
    );
    expect(result.header.epgUrls, [
      'http://a.example/epg.xml',
      'http://b.example/epg.xml.gz',
      'http://c.example/g.xml',
    ]);
    expect(result.header.catchup, 'append');
    expect(result.header.catchupSource, '?utc={utc}');
    expect(result.header.catchupDays, 7);
    expect(result.header.tvgShift, -1.5);
  });

  test('reads every #EXTINF attribute', () async {
    final result = await parse(
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="bbc1.uk" tvg-name="BBC One" tvg-logo="http://l.example/bbc.png" tvg-chno="101" '
      'group-title="UK, General" tvg-shift="1" catchup="flussonic" catchup-days="3" '
      'catchup-source="http://x.example/{utc}" radio="false",BBC One HD\n'
      'http://s.example/bbc1.m3u8\n',
    );
    final e = result.entries.single;
    expect(e.tvgId, 'bbc1.uk');
    expect(e.tvgName, 'BBC One');
    expect(e.tvgLogo, 'http://l.example/bbc.png');
    expect(e.tvgChno, '101');
    expect(e.group, 'UK, General', reason: 'a comma inside quotes is not the title separator');
    expect(e.tvgShift, 1);
    expect(e.catchup, 'flussonic');
    expect(e.catchupDays, 3);
    expect(e.catchupSource, 'http://x.example/{utc}');
    expect(e.isRadio, isFalse);
    expect(e.title, 'BBC One HD');
    expect(e.duration, -1);
    expect(e.url, 'http://s.example/bbc1.m3u8');
  });

  test(
    'accepts unquoted and single-quoted values, attributes glued to the duration and a comma in the title',
    () async {
      final result = await parse(
        '#EXTINF:-1tvg-id=abc group-title=\'Kids\' radio=true,News, Weather & Sport\n'
        'http://s.example/a\n',
      );
      final e = result.entries.single;
      expect(e.tvgId, 'abc');
      expect(e.group, 'Kids');
      expect(e.isRadio, isTrue);
      expect(e.title, 'News, Weather & Sport');
    },
  );

  test('handles a byte-order mark, CRLF, blank lines and a missing header', () async {
    final result = await parse(
      '\uFEFF#EXTINF:0 tvg-id="x",First\r\n\r\nhttp://s.example/1\r\n#EXTINF:-1,Second\r\nhttp://s.example/2',
    );
    expect(result.entries.map((e) => e.title), ['First', 'Second']);
    expect(result.entries.first.url, 'http://s.example/1');
    expect(result.entries.last.url, 'http://s.example/2');
  });

  test('#EXTGRP is the group when there is no group-title', () async {
    final result = await parse(
      '#EXTINF:-1,A\n#EXTGRP:Movies\nhttp://s.example/a\n#EXTINF:-1 group-title="G",B\n#EXTGRP:X\nhttp://s.example/b\n',
    );
    expect(result.entries[0].group, 'Movies');
    expect(result.entries[1].group, 'G');
  });

  test('collects headers from #EXTVLCOPT, #KODIPROP and the URL suffix (the suffix wins)', () async {
    final result = await parse(
      '#EXTINF:-1,A\n'
      '#EXTVLCOPT:http-user-agent=VLC/3\n'
      '#EXTVLCOPT:http-referrer=http://ref.example/\n'
      '#EXTVLCOPT:http-origin=http://origin.example\n'
      '#KODIPROP:inputstream.adaptive.stream_headers=Cookie=a%3Db&X-Custom=1\n'
      '#KODIPROP:inputstream.adaptive.license_type=clearkey\n'
      'http://s.example/a.m3u8|User-Agent=Override%2F2&Referer=http%3A%2F%2Fr2.example%2F\n',
    );
    final e = result.entries.single;
    expect(e.url, 'http://s.example/a.m3u8');
    expect(e.headers['User-Agent'], 'Override/2');
    expect(e.headers['Referer'], 'http://r2.example/');
    expect(e.headers['Origin'], 'http://origin.example');
    expect(e.headers['Cookie'], 'a=b');
    expect(e.headers['X-Custom'], '1');
    expect(e.kodiProps['inputstream.adaptive.license_type'], 'clearkey');
  });

  test('directives of one entry never leak into the next', () async {
    final result = await parse(
      '#EXTINF:-1 group-title="A",One\n#EXTVLCOPT:http-user-agent=UA\nhttp://s.example/1\n#EXTINF:-1,Two\nhttp://s.example/2\n',
    );
    expect(result.entries[1].headers, isEmpty);
    expect(result.entries[1].group, isNull);
  });

  test('an entry without #EXTINF is named after its URL', () async {
    final result = await parse('http://s.example/path/stream.ts\n');
    expect(result.entries.single.displayName, 'stream.ts');
  });

  test('streams a large playlist (60k entries) in one pass', () async {
    Stream<List<int>> lines() async* {
      yield utf8.encode('#EXTM3U url-tvg="http://g.example/epg.xml"\n');
      for (var i = 0; i < 60000; i++) {
        yield utf8.encode(
          '#EXTINF:-1 tvg-id="c$i" tvg-name="Channel $i" tvg-logo="http://l.example/$i.png" group-title="G${i % 40}",Channel $i\n'
          'http://s.example/live/$i.ts\n',
        );
      }
    }

    var count = 0;
    String? last;
    final watch = Stopwatch()..start();
    final header = await M3uStreamParser.parse(M3uStreamParser.linesOf(lines()), (e) {
      count++;
      last = e.tvgId;
    });
    watch.stop();
    expect(count, 60000);
    expect(last, 'c59999');
    expect(header.epgUrls, ['http://g.example/epg.xml']);
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });
}
