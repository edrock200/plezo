import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';

Future<({List<XmltvChannel> channels, List<XmltvProgramme> programmes})> parse(
  List<int> bytes, {
  bool Function(String, int, int)? keep,
  int chunk = 1 << 30,
}) async {
  final channels = <XmltvChannel>[];
  final programmes = <XmltvProgramme>[];
  final parser = XmltvStreamParser(onChannel: channels.add, onProgramme: programmes.add, keepProgramme: keep);
  Stream<List<int>> chunks() async* {
    for (var i = 0; i < bytes.length; i += chunk) {
      yield bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk);
    }
  }

  await parser.parseBytes(chunks());
  return (channels: channels, programmes: programmes);
}

const sample = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv generator-info-name="test">
  <channel id="one.example">
    <display-name lang="en">Channel One</display-name>
    <display-name>One HD</display-name>
    <icon src="http://l.example/one.png" />
  </channel>
  <channel id="two.example"><display-name>Two &amp; Co</display-name></channel>
  <programme start="20261126183000 +0100" stop="20261126193000 +0100" channel="one.example">
    <title lang="en">News &amp; Weather</title>
    <sub-title>Evening</sub-title>
    <desc><![CDATA[Today's <b>headlines</b>.]]></desc>
    <category>News</category>
    <icon src="http://l.example/p.png"/>
    <episode-num system="xmltv_ns">2.4.0/1</episode-num>
    <episode-num system="onscreen">S03E05</episode-num>
    <rating system="VCHIP"><value>TV-PG</value></rating>
    <date>2026</date>
  </programme>
  <programme start="20261126173000" stop="20261126180000" channel="two.example">
    <title>Quiz</title>
    <episode-num system="xmltv_ns">.9.</episode-num>
  </programme>
  <programme start="202611261800 -0500" channel="two.example"><title>No stop</title></programme>
  <programme start="garbage" channel="two.example"><title>Bad</title></programme>
</tv>
''';

void main() {
  test('times: offsets, no zone (UTC), minutes only, garbage', () {
    expect(parseXmltvTime('20261126183000 +0100'), DateTime.utc(2026, 11, 26, 17, 30).millisecondsSinceEpoch ~/ 1000);
    expect(parseXmltvTime('20261126183000 -0530'), DateTime.utc(2026, 11, 27, 0, 0).millisecondsSinceEpoch ~/ 1000);
    expect(parseXmltvTime('20261126183000'), DateTime.utc(2026, 11, 26, 18, 30).millisecondsSinceEpoch ~/ 1000);
    expect(parseXmltvTime('202611261830 +02:00'), DateTime.utc(2026, 11, 26, 16, 30).millisecondsSinceEpoch ~/ 1000);
    expect(parseXmltvTime('garbage'), isNull);
    expect(parseXmltvTime(null), isNull);
  });

  test('xmltv_ns episode numbers are zero-based', () {
    expect(parseXmltvNs('2.4.0/1'), (season: 3, episode: 5, label: 'S03E05'));
    expect(parseXmltvNs('.9.'), (season: null, episode: 10, label: 'E10'));
    expect(parseXmltvNs(''), (season: null, episode: null, label: null));
  });

  test('reads channels and programmes, entities and CDATA', () async {
    final r = await parse(utf8.encode(sample));
    expect(r.channels, hasLength(2));
    expect(r.channels[0].id, 'one.example');
    expect(r.channels[0].displayNames, ['Channel One', 'One HD']);
    expect(r.channels[0].icon, 'http://l.example/one.png');
    expect(r.channels[1].displayNames, ['Two & Co']);

    expect(r.programmes, hasLength(3), reason: 'the one with an unreadable start is skipped');
    final news = r.programmes[0];
    expect(news.channel, 'one.example');
    expect(news.start, DateTime.utc(2026, 11, 26, 17, 30).millisecondsSinceEpoch ~/ 1000);
    expect(news.stop - news.start, 3600);
    expect(news.title, 'News & Weather');
    expect(news.subTitle, 'Evening');
    expect(news.description, "Today's <b>headlines</b>.");
    expect(news.category, 'News');
    expect(news.icon, 'http://l.example/p.png');
    expect(news.episode, 'S03E05', reason: 'onscreen wins for the label');
    expect(news.season, 3);
    expect(news.episodeNumber, 5);
    expect(news.rating, 'TV-PG');
    expect(news.year, 2026);

    expect(r.programmes[1].episode, 'E10');
    expect(r.programmes[2].stop - r.programmes[2].start, 3600, reason: 'no stop: an hour');
  });

  test('the same result whatever the chunk boundaries', () async {
    final whole = await parse(utf8.encode(sample));
    final split = await parse(utf8.encode(sample), chunk: 7);
    expect(
      split.programmes.map((p) => '${p.channel}${p.start}${p.title}'),
      whole.programmes.map((p) => '${p.channel}${p.start}${p.title}'),
    );
  });

  test('reads gzip input by its magic bytes', () async {
    final r = await parse(gzip.encode(utf8.encode(sample)), chunk: 64);
    expect(r.channels, hasLength(2));
    expect(r.programmes, hasLength(3));
  });

  test('the keep filter skips programmes before their children are kept', () async {
    final r = await parse(utf8.encode(sample), keep: (channel, start, stop) => channel == 'one.example');
    expect(r.programmes.map((p) => p.channel), ['one.example']);
  });

  test('streams a large guide (200k programmes) without building a document', () async {
    final start = DateTime.utc(2026, 11, 26);
    String t(DateTime d) {
      String two(int v) => v.toString().padLeft(2, '0');
      return '${d.year}${two(d.month)}${two(d.day)}${two(d.hour)}${two(d.minute)}00 +0000';
    }

    Stream<List<int>> guide() async* {
      yield utf8.encode('<tv>');
      for (var c = 0; c < 500; c++) {
        yield utf8.encode('<channel id="c$c"><display-name>C $c</display-name></channel>');
      }
      final buffer = StringBuffer();
      for (var c = 0; c < 500; c++) {
        for (var i = 0; i < 400; i++) {
          final s = start.add(Duration(minutes: 30 * i));
          buffer.write(
            '<programme start="${t(s)}" stop="${t(s.add(const Duration(minutes: 30)))}" channel="c$c">'
            '<title>P $i</title><desc>Description $i of channel $c</desc></programme>',
          );
        }
        yield utf8.encode(buffer.toString());
        buffer.clear();
      }
      yield utf8.encode('</tv>');
    }

    var count = 0;
    final parser = XmltvStreamParser(onChannel: (_) {}, onProgramme: (_) => count++);
    final watch = Stopwatch()..start();
    await parser.parseBytes(guide());
    expect(count, 200000);
    expect(parser.channels, 500);
    expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
  });
}
