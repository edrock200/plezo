import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/silo_overlay_icons.dart';

/// The path's drawn extent (getBounds includes curve control points).
Rect _tight(Path path) {
  var bounds = Rect.zero;
  var first = true;
  for (final metric in path.computeMetrics()) {
    for (var d = 0.0; d <= metric.length; d += 0.05) {
      final p = metric.getTangentForOffset(d)!.position;
      final point = Rect.fromLTWH(p.dx, p.dy, 0, 0);
      bounds = first ? point : bounds.expandToInclude(point);
      first = false;
    }
  }
  return bounds;
}

void main() {
  test('the SVG path reader handles compact numbers, relative commands and arcs', () {
    final line = parseSvgPath('M20 6 9 17l-5-5').getBounds();
    expect(line, const Rect.fromLTRB(4, 6, 20, 17));
    // `.705.705` is two numbers; `a…0 0 0-1.203-.498` packs a sign after a flag.
    final volume = _tight(parseSvgPath('M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587'));
    // Sweep 0 bulges the speaker's wave to the right, to x = 13 + 9.
    expect(_tight(parseSvgPath('M19.364 18.364a9 9 0 0 0 0-12.728')).right, closeTo(22, 0.05));
    expect(volume.right, closeTo(11, 0.01));
    expect(volume.left, closeTo(6.413, 0.01));
    final circle = _tight(parseSvgPath('M12 2a10 10 0 0 1 0 20 10 10 0 0 1 0-20z'));
    expect(circle.left, closeTo(2, 0.05));
    expect(circle.right, closeTo(22, 0.05));
    expect(parseSvgPath('M1 1h4v4H1z').getBounds(), const Rect.fromLTRB(1, 1, 5, 5));
  });

  test('every generic badge icon and the Dolby Vision mark fit their grids', () {
    for (final icon in [
      'clock',
      'tv',
      'film',
      'subtitles',
      'languages',
      'building',
      'shield',
      'layout',
      'monitor',
      'volume',
      'globe',
      'users',
    ]) {
      expect(SiloOverlayIcons.has(icon), isTrue, reason: icon);
      final bounds = _tight(SiloOverlayIcons.path(icon)!);
      expect(bounds.isEmpty, isFalse, reason: icon);
      expect(const Rect.fromLTRB(0, 0, 24, 24).inflate(0.01).contains(bounds.topLeft), isTrue, reason: icon);
      expect(bounds.right <= 24.01 && bounds.bottom <= 24.01, isTrue, reason: icon);
    }
    final dv = _tight(SiloOverlayIcons.path('dolby-vision')!);
    expect(dv.left, closeTo(2, 0.05));
    expect(dv.right, closeTo(14, 0.05));
    expect(SiloOverlayIcons.has('atmos'), isFalse, reason: 'wordmarks are text');
    expect(SiloOverlayIcons.path('nope'), isNull);
  });
}
