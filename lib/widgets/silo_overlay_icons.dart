import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The glyphs Silo's card overlays draw: the generic badge icons are the
/// Lucide icons Silo's web client maps them to (`web/src/lib/overlays/icons.tsx`),
/// drawn from lucide-react 0.576.0's icon data with Lucide's defaults (stroke
/// 2 on a 24-unit grid, round caps and joins, no fill), as Silo Android #882
/// does. Dolby Vision is the web's own mark (a ring with its right half
/// filled), not Dolby artwork. Wordmarks (HDR, HDR10, ATMOS, AV1) are text,
/// drawn by the badge. Lucide is ISC-licensed (Feather portions MIT); the
/// notice is on the licenses page.
abstract final class SiloOverlayIcons {
  static const _grid = 24.0;

  /// Each icon's elements on Lucide's 24-unit grid, copied from lucide-react
  /// 0.576.0 (`dist/esm/icons/<name>.js`; `subtitles` is `captions`).
  static const Map<String, List<_El>> _lucide = {
    'clock': [_Circle(12, 12, 10), _P('M12 6v6l4 2')],
    'tv': [_P('m17 2-5 5-5-5'), _Rect(2, 7, 20, 15, 2)],
    'film': [
      _Rect(3, 3, 18, 18, 2),
      _P('M7 3v18'),
      _P('M3 7.5h4'),
      _P('M3 12h18'),
      _P('M3 16.5h4'),
      _P('M17 3v18'),
      _P('M17 7.5h4'),
      _P('M17 16.5h4'),
    ],
    'subtitles': [_Rect(3, 5, 18, 14, 2), _P('M7 15h4M15 15h2M7 11h2M13 11h4')],
    'languages': [
      _P('m5 8 6 6'),
      _P('m4 14 6-6 2-3'),
      _P('M2 5h12'),
      _P('M7 2h1'),
      _P('m22 22-5-10-5 10'),
      _P('M14 18h6'),
    ],
    'building': [
      _P('M10 12h4'),
      _P('M10 8h4'),
      _P('M14 21v-3a2 2 0 0 0-4 0v3'),
      _P('M6 10H4a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-2'),
      _P('M6 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16'),
    ],
    'shield': [
      _P(
        'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 '
        '6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z',
      ),
    ],
    'layout': [_Rect(3, 3, 18, 7, 1), _Rect(3, 14, 9, 7, 1), _Rect(16, 14, 5, 7, 1)],
    'monitor': [_Rect(2, 3, 20, 14, 2), _Line(8, 21, 16, 21), _Line(12, 17, 12, 21)],
    'volume': [
      _P(
        'M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 '
        '1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z',
      ),
      _P('M16 9a5 5 0 0 1 0 6'),
      _P('M19.364 18.364a9 9 0 0 0 0-12.728'),
    ],
    'globe': [_Circle(12, 12, 10), _P('M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20'), _P('M2 12h20')],
    'users': [
      _P('M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2'),
      _P('M16 3.128a4 4 0 0 1 0 7.744'),
      _P('M22 21v-2a4 4 0 0 0-3-3.87'),
      _Circle(9, 7, 4),
    ],
  };

  /// The web's `DolbyVisionMark` on its 16-unit grid.
  static const _dolbyVision =
      'M8 2c3.3 0 6 2.7 6 6s-2.7 6-6 6-6-2.7-6-6 2.7-6 6-6zm0 1.5A4.5 4.5 0 1 0 8 12.5'
      'a4.5 4.5 0 0 0 0-9zm0 0v9a4.5 4.5 0 0 0 0-9z';

  /// Lucide's `Check`, the watched corner's mark.
  static const _check = 'M20 6 9 17l-5-5';

  static final Map<String, Path> _paths = {};

  /// Whether [icon] is drawn as a glyph (not a wordmark or nothing).
  static bool has(String icon) => icon == 'dolby-vision' || _lucide.containsKey(icon);

  /// [icon]'s path on its own grid (24 units; 16 for Dolby Vision), parsed
  /// once; null for an icon without a glyph.
  static Path? path(String icon) {
    final hit = _paths[icon];
    if (hit != null) return hit;
    final Path? built;
    if (icon == 'dolby-vision') {
      built = parseSvgPath(_dolbyVision);
    } else if (icon == 'check') {
      built = parseSvgPath(_check);
    } else if (_lucide[icon] case final elements?) {
      built = Path();
      for (final element in elements) {
        built.addPath(element.toPath(), Offset.zero);
      }
    } else {
      built = null;
    }
    if (built != null) _paths[icon] = built;
    return built;
  }
}

sealed class _El {
  const _El();
  Path toPath();
}

class _P extends _El {
  const _P(this.d);
  final String d;
  @override
  Path toPath() => parseSvgPath(d);
}

class _Circle extends _El {
  const _Circle(this.cx, this.cy, this.r);
  final double cx;
  final double cy;
  final double r;
  @override
  Path toPath() => Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
}

class _Rect extends _El {
  const _Rect(this.x, this.y, this.w, this.h, this.rx);
  final double x;
  final double y;
  final double w;
  final double h;
  final double rx;
  @override
  Path toPath() => Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(rx)));
}

class _Line extends _El {
  const _Line(this.x1, this.y1, this.x2, this.y2);
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  @override
  Path toPath() => Path()
    ..moveTo(x1, y1)
    ..lineTo(x2, y2);
}

/// An SVG path's `d` as a [Path]: M, L, H, V, C, S, Q, T, A and Z, absolute
/// and relative, with SVG's compact number syntax (`.5.5`, `1-.8`, packed arc
/// flags). Enough for icon data; an unknown command ends the path there.
Path parseSvgPath(String d) {
  final path = Path();
  final s = _PathScanner(d);
  var cx = 0.0, cy = 0.0; // current point
  var sx = 0.0, sy = 0.0; // subpath start
  var lastControlX = 0.0, lastControlY = 0.0;
  var lastCommand = '';
  String? command;
  while (true) {
    s.skipSeparators();
    if (s.done) break;
    final c = s.peek;
    if (_isCommand(c)) {
      command = c;
      s.advance();
    } else if (command == null) {
      break;
    }
    final cmd = command;
    final relative = cmd == cmd.toLowerCase();
    final ox = relative ? cx : 0.0;
    final oy = relative ? cy : 0.0;
    switch (cmd.toUpperCase()) {
      case 'M':
        cx = ox + s.number();
        cy = oy + s.number();
        path.moveTo(cx, cy);
        sx = cx;
        sy = cy;
        // Further pairs after a moveto are linetos.
        command = relative ? 'l' : 'L';
      case 'L':
        cx = ox + s.number();
        cy = oy + s.number();
        path.lineTo(cx, cy);
      case 'H':
        cx = ox + s.number();
        path.lineTo(cx, cy);
      case 'V':
        cy = oy + s.number();
        path.lineTo(cx, cy);
      case 'C':
        final x1 = ox + s.number(), y1 = oy + s.number();
        final x2 = ox + s.number(), y2 = oy + s.number();
        cx = ox + s.number();
        cy = oy + s.number();
        path.cubicTo(x1, y1, x2, y2, cx, cy);
        lastControlX = x2;
        lastControlY = y2;
      case 'S':
        final reflect = lastCommand == 'C' || lastCommand == 'S';
        final x1 = reflect ? 2 * cx - lastControlX : cx;
        final y1 = reflect ? 2 * cy - lastControlY : cy;
        final x2 = ox + s.number(), y2 = oy + s.number();
        cx = ox + s.number();
        cy = oy + s.number();
        path.cubicTo(x1, y1, x2, y2, cx, cy);
        lastControlX = x2;
        lastControlY = y2;
      case 'Q':
        final x1 = ox + s.number(), y1 = oy + s.number();
        cx = ox + s.number();
        cy = oy + s.number();
        path.quadraticBezierTo(x1, y1, cx, cy);
        lastControlX = x1;
        lastControlY = y1;
      case 'T':
        final reflect = lastCommand == 'Q' || lastCommand == 'T';
        final x1 = reflect ? 2 * cx - lastControlX : cx;
        final y1 = reflect ? 2 * cy - lastControlY : cy;
        cx = ox + s.number();
        cy = oy + s.number();
        path.quadraticBezierTo(x1, y1, cx, cy);
        lastControlX = x1;
        lastControlY = y1;
      case 'A':
        final rx = s.number().abs(), ry = s.number().abs();
        final rotation = s.number();
        final largeArc = s.flag();
        final sweep = s.flag();
        cx = ox + s.number();
        cy = oy + s.number();
        if (rx == 0 || ry == 0) {
          path.lineTo(cx, cy);
        } else {
          path.arcToPoint(
            Offset(cx, cy),
            radius: Radius.elliptical(rx, ry),
            rotation: rotation,
            largeArc: largeArc,
            clockwise: sweep,
          );
        }
      case 'Z':
        path.close();
        cx = sx;
        cy = sy;
        command = null;
      default:
        return path;
    }
    lastCommand = cmd.toUpperCase();
    if (s.failed) break;
  }
  return path;
}

bool _isCommand(String c) => 'MmLlHhVvCcSsQqTtAaZz'.contains(c);

class _PathScanner {
  _PathScanner(this.d);
  final String d;
  var i = 0;
  var failed = false;

  bool get done => i >= d.length;
  String get peek => d[i];
  void advance() => i++;

  void skipSeparators() {
    while (i < d.length && (d[i] == ' ' || d[i] == ',' || d[i] == '\n' || d[i] == '\t' || d[i] == '\r')) {
      i++;
    }
  }

  /// An arc flag: one `0` or `1`, which SVG lets touch the next number.
  bool flag() {
    skipSeparators();
    if (i < d.length && (d[i] == '0' || d[i] == '1')) return d[i++] == '1';
    failed = true;
    return false;
  }

  double number() {
    skipSeparators();
    final start = i;
    if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
    var dot = false;
    while (i < d.length) {
      final c = d[i];
      if (c == '.') {
        if (dot) break;
        dot = true;
      } else if (c.codeUnitAt(0) < 0x30 || c.codeUnitAt(0) > 0x39) {
        break;
      }
      i++;
    }
    if (i < d.length && (d[i] == 'e' || d[i] == 'E')) {
      i++;
      if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
      while (i < d.length && d.codeUnitAt(i) >= 0x30 && d.codeUnitAt(i) <= 0x39) {
        i++;
      }
    }
    final value = double.tryParse(d.substring(start, i));
    if (value == null) {
      failed = true;
      i = d.length;
      return 0;
    }
    return value;
  }
}

/// A badge glyph [size] square, tinted [color].
class SiloOverlayGlyph extends StatelessWidget {
  const SiloOverlayGlyph({super.key, required this.icon, required this.size, required this.color, this.shadow});

  final String icon;
  final double size;
  final Color color;

  /// A text shadow the badge's text draws, drawn under the glyph too.
  final Shadow? shadow;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GlyphPainter(icon, color, shadow));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.icon, this.color, this.shadow);

  final String icon;
  final Color color;
  final Shadow? shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = SiloOverlayIcons.path(icon);
    if (path == null) return;
    final filled = icon == 'dolby-vision';
    final grid = filled ? 16.0 : SiloOverlayIcons._grid;
    final scale = size.width / grid;
    final scaled = path.transform(Matrix4.diagonal3Values(scale, scale, 1).storage);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (!filled) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
    }
    final shadow = this.shadow;
    if (shadow != null && shadow.color.a > 0) {
      final shadowPaint = Paint()
        ..color = shadow.color
        ..style = paint.style
        ..strokeWidth = paint.strokeWidth
        ..strokeCap = paint.strokeCap
        ..strokeJoin = paint.strokeJoin
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, Shadow.convertRadiusToSigma(shadow.blurRadius));
      canvas.drawPath(scaled.shift(shadow.offset), shadowPaint);
    }
    canvas.drawPath(scaled, paint);
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.icon != icon || old.color != color || old.shadow != shadow;
}

/// The watched corner (the web's `CardWatchStatus`): Lucide's `Check` in
/// white at 62% of an emerald disc with a 1 px white ring and Tailwind's
/// `shadow-sm`.
class SiloWatchedCheck extends StatelessWidget {
  const SiloWatchedCheck({super.key});

  /// Tailwind's `emerald-500`.
  static const disc = Color(0xFF00BC7D);

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      color: disc,
      shape: BoxShape.circle,
      border: Border.fromBorderSide(BorderSide(color: Color(0x59FFFFFF))),
      boxShadow: siloShadowSm,
    ),
    child: CustomPaint(painter: _CheckPainter()),
  );
}

/// Tailwind's `shadow-sm`: `0 1px 3px rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)`.
const siloShadowSm = [
  BoxShadow(color: Color(0x1A000000), offset: Offset(0, 1), blurRadius: 1.73),
  BoxShadow(color: Color(0x1A000000), offset: Offset(0, 1), blurRadius: 0.87, spreadRadius: -1),
];

class _CheckPainter extends CustomPainter {
  const _CheckPainter();

  /// The check's share of the disc and its stroke on Lucide's grid.
  static const _share = 0.62;
  static const _stroke = 3.25;

  @override
  void paint(Canvas canvas, Size size) {
    final box = math.min(size.width, size.height) * _share;
    final unit = box / SiloOverlayIcons._grid;
    final path = SiloOverlayIcons.path('check')!;
    final placed = path
        .transform(Matrix4.diagonal3Values(unit, unit, 1).storage)
        .shift(Offset((size.width - box) / 2, (size.height - box) / 2));
    canvas.drawPath(
      placed,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => false;
}
