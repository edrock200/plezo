import 'dart:convert';
import 'dart:typed_data';

/// Splits a JSON answer into its top-level elements while the bytes arrive,
/// so a list of hundreds of thousands of rows is never held (or decoded) as
/// a whole: each element's bytes are decoded alone once they are complete.
///
/// - `[a, b, …]` yields each element;
/// - `{"0": a, "1": b, …}` (some Xtream servers key rows by index) yields
///   each value;
/// - `null`, `{}`, `[]`, `false`, a number or a string yield nothing;
/// - anything else (an HTML error page) is a [FormatException], and so is an
///   answer that ends inside the list ([close]).
///
/// Works on UTF-8 bytes: every structural character is ASCII, and the bytes
/// of a multi-byte character are all 0x80 or above, so a character split
/// across two chunks is simply carried over with the element's bytes.
class JsonArraySplitter {
  JsonArraySplitter({this.decode = _decode});

  /// Turns one element's bytes into its value (default: UTF-8 + JSON).
  final Object? Function(Uint8List bytes) decode;

  static Object? _decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes, allowMalformed: true));

  static const _lbrace = 0x7b, _rbrace = 0x7d, _lbracket = 0x5b, _rbracket = 0x5d;
  static const _quote = 0x22, _backslash = 0x5c, _comma = 0x2c, _colon = 0x3a;

  static bool _isSpace(int b) => b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09;

  // Top level: 0 = not started, 1 = in the array, 2 = in the object,
  // 3 = finished (or a scalar top level, whose rest is ignored).
  int _top = 0;
  bool _bom = true;

  // Inside the top container.
  bool _expectKey = true; // object: a key comes next (else its value)
  bool _inKey = false;
  bool _keyEscape = false;

  // The element being read.
  BytesBuilder? _element;
  int _depth = 0; // nesting inside the element
  bool _inString = false;
  bool _escape = false;
  bool _scalar = false; // a number / true / false / null element

  /// How many elements were produced so far.
  int count = 0;

  bool get done => _top == 3;

  /// Feed the next chunk; returns the elements it completed, in order.
  List<Object?> add(List<int> chunk) {
    final out = <Object?>[];
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var i = 0;
    final n = bytes.length;
    // Start of the current element's bytes within this chunk.
    var mark = _element == null ? -1 : 0;

    void finish(int endExclusive) {
      final builder = _element!;
      if (endExclusive > mark) builder.add(Uint8List.sublistView(bytes, mark, endExclusive));
      _element = null;
      mark = -1;
      _scalar = false;
      out.add(decode(builder.takeBytes()));
      count++;
    }

    while (i < n) {
      final b = bytes[i];
      if (_top == 3) break;
      if (_top == 0) {
        if (_bom && i + 2 < n && b == 0xef && bytes[i + 1] == 0xbb && bytes[i + 2] == 0xbf) {
          i += 3;
          _bom = false;
          continue;
        }
        _bom = false;
        if (_isSpace(b)) {
          i++;
          continue;
        }
        if (b == _lbracket) {
          _top = 1;
        } else if (b == _lbrace) {
          _top = 2;
          _expectKey = true;
        } else if (b == _quote || b == 0x2d || (b >= 0x30 && b <= 0x39) || b == 0x6e || b == 0x74 || b == 0x66) {
          // A string, number, null, true or false: no rows.
          _top = 3;
          break;
        } else {
          throw const FormatException('the answer is not JSON');
        }
        i++;
        continue;
      }

      if (_element != null) {
        // Inside an element.
        if (_scalar) {
          if (_isSpace(b) || b == _comma || b == _rbracket || b == _rbrace) {
            finish(i);
            continue; // the delimiter is handled at the top level
          }
          i++;
          continue;
        }
        if (_inString) {
          if (_escape) {
            _escape = false;
          } else if (b == _backslash) {
            _escape = true;
          } else if (b == _quote) {
            _inString = false;
            if (_depth == 0) {
              finish(i + 1);
              i++;
              continue;
            }
          }
          i++;
          continue;
        }
        if (b == _quote) {
          _inString = true;
        } else if (b == _lbrace || b == _lbracket) {
          _depth++;
        } else if (b == _rbrace || b == _rbracket) {
          _depth--;
          if (_depth == 0) {
            finish(i + 1);
            i++;
            continue;
          }
        }
        i++;
        continue;
      }

      // Between elements, in the top container.
      if (_inKey) {
        if (_keyEscape) {
          _keyEscape = false;
        } else if (b == _backslash) {
          _keyEscape = true;
        } else if (b == _quote) {
          _inKey = false;
        }
        i++;
        continue;
      }
      if (_isSpace(b) || b == _comma) {
        i++;
        continue;
      }
      if ((_top == 1 && b == _rbracket) || (_top == 2 && b == _rbrace)) {
        _top = 3;
        break;
      }
      if (_top == 2 && _expectKey) {
        if (b == _quote) {
          _inKey = true;
        } else if (b == _colon) {
          _expectKey = false;
        } else {
          throw const FormatException('malformed object');
        }
        i++;
        continue;
      }
      if (_top == 2 && b == _colon) {
        i++;
        continue;
      }
      // An element starts here.
      _element = BytesBuilder(copy: false);
      mark = i;
      _depth = 0;
      _inString = false;
      _escape = false;
      _scalar = false;
      if (_top == 2) _expectKey = true;
      if (b == _quote) {
        _inString = true;
      } else if (b == _lbrace || b == _lbracket) {
        _depth = 1;
      } else {
        _scalar = true;
      }
      i++;
    }
    // Carry the unfinished element's bytes over to the next chunk.
    final element = _element;
    if (element != null && mark >= 0 && mark < n) {
      element.add(Uint8List.fromList(Uint8List.sublistView(bytes, mark, n)));
    }
    return out;
  }

  /// The answer ended. Throws when it ended inside the list.
  void close() {
    if (_top == 1 || _top == 2) throw const FormatException('the answer ended early');
  }
}
