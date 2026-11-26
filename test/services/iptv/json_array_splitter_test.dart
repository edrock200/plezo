import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/json_array_splitter.dart';

/// Feeds [text] in chunks of [size] bytes and returns every element.
List<Object?> split(String text, {int size = 1}) {
  final bytes = utf8.encode(text);
  final splitter = JsonArraySplitter();
  final out = <Object?>[];
  for (var i = 0; i < bytes.length; i += size) {
    out.addAll(splitter.add(bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size)));
  }
  splitter.close();
  return out;
}

void main() {
  const tricky =
      ' \n[ {"name": "A [bracket] {brace}", "q": "say \\"hi\\"", "nested": {"list": [1, [2, {"x": "]"}]]}},\n'
      '  {"name": "back\\\\slash\\\\", "u": "\\u00e9t\\u00e9", "emoji": "Ünïcödé 🎬 日本"},\n'
      '  [1, 2], "a string", 42, -1.5e3, true, false, null ]  ';

  test('every element, whatever the chunk size', () {
    final expected = jsonDecode(tricky) as List;
    for (final size in [1, 2, 3, 5, 7, 64, 100000]) {
      expect(split(tricky, size: size), expected, reason: 'chunk size $size');
    }
  });

  test('multi-byte characters split across chunks stay whole', () {
    const text = '[{"t": "日本語のタイトル 🎬"}, {"t": "é"}]';
    for (var size = 1; size < 8; size++) {
      expect(split(text, size: size), [
        {'t': '日本語のタイトル 🎬'},
        {'t': 'é'},
      ]);
    }
  });

  test('empty lists, null, {} and scalars yield nothing', () {
    for (final text in ['[]', ' [ ] ', '{}', 'null', '', '   ', 'false', '0', '"text"']) {
      expect(split(text), isEmpty, reason: text);
    }
  });

  test('an object keyed by index yields its values', () {
    expect(split('{"0": {"id": 1}, "1": {"id": "x,}"}, "2\\"": [3]}', size: 2), [
      {'id': 1},
      {'id': 'x,}'},
      [3],
    ]);
  });

  test('a byte order mark is skipped', () {
    final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode('[1]')];
    final splitter = JsonArraySplitter();
    expect(splitter.add(bytes), [1]);
    splitter.close();
  });

  test('truncated input fails on close, after the complete elements', () {
    final splitter = JsonArraySplitter();
    final got = splitter.add(utf8.encode('[{"a": 1}, {"b": "unfinish'));
    expect(got, [
      {'a': 1},
    ]);
    expect(splitter.close, throwsFormatException);
    final cut = JsonArraySplitter()..add(utf8.encode('[1, 2'));
    expect(cut.close, throwsFormatException);
  });

  test('an HTML error page is not JSON', () {
    expect(() => JsonArraySplitter().add(utf8.encode('<html>error</html>')), throwsFormatException);
  });

  test('stops at the end of the list', () {
    final splitter = JsonArraySplitter();
    expect(splitter.add(utf8.encode('[1] trailing garbage [2]')), [1]);
    expect(splitter.done, isTrue);
    splitter.close();
  });
}
