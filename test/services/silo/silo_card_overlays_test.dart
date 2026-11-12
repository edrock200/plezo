import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/silo_card_overlay_store.dart';
import 'package:plezy/services/silo/silo_card_overlays.dart';

final _ref = '${'a' * 64}.webp';
final _ref2 = '${'b' * 64}.webp';

SiloOverlayData _data(Map<String, Object?> json) => SiloOverlayData.fromJson(json);

SiloOverlayPrefs _prefs(Map<String, Object?> items, {String preset = 'classic', List<String> order = const []}) =>
    SiloOverlayPrefs.parse({'version': 2, 'preset': preset, 'order': order, 'items': items});

List<String> _ids(List<SiloOverlayBadge> badges) => [for (final b in badges) b.id];

void main() {
  group('document', () {
    test('defaults come from the registry with the classic look', () {
      final prefs = SiloOverlayPrefs.defaults();
      expect(prefs.preset, 'classic');
      expect(prefs.items['resolution']!.enabled, isTrue);
      expect(prefs.items['resolution']!.position, SiloOverlayPosition.topLeft);
      expect(prefs.items['release_type']!.position, SiloOverlayPosition.bottomLeft);
      expect(prefs.items['rating_imdb']!.enabled, isFalse);
      expect(prefs.items['rating_imdb']!.position, SiloOverlayPosition.leftEdge);
      expect(prefs.items['resolution_hdr_audio']!.enabled, isFalse);
    });

    test('a v2 document keeps its preset, order, overrides and images; invalid fields are dropped', () {
      final prefs = SiloOverlayPrefs.parse({
        'version': 2,
        'preset': 'plate',
        'order': ['audio', 'nope', 'resolution', 'audio'],
        'style': {'size': 1.5, 'shape': 'rounded', 'background': '#112233cc', 'borderWidth': 2, 'uppercase': false},
        'items': {
          'resolution': {'enabled': false, 'position': 'bottom-right', 'accentColor': '#ff0000', 'showIcon': true},
          'audio': {'position': 'top-right', 'accentColor': 'red', 'image': _ref},
          'hdr': {
            'valueImages': {'DV': _ref2, 'HDR10': 'not-a-ref'},
          },
          'unknown_badge': {'enabled': true},
        },
      });
      expect(prefs.preset, 'plate');
      expect(prefs.order, ['audio', 'resolution']);
      expect(prefs.style!.size, 1.5);
      expect(prefs.style!.shape, 'rounded');
      expect(prefs.style!.background, '#112233cc');
      expect(prefs.style!.borderWidth, 2);
      expect(prefs.style!.uppercase, isFalse);
      final resolution = prefs.items['resolution']!;
      expect(resolution.enabled, isFalse);
      expect(resolution.position, SiloOverlayPosition.bottomRight);
      expect(resolution.accent, '#ff0000');
      expect(resolution.showIcon, isTrue);
      final audio = prefs.items['audio']!;
      // A stored top-right badge moves to the right-edge rail.
      expect(audio.position, SiloOverlayPosition.rightEdge);
      expect(audio.accent, isNull);
      expect(audio.image, _ref);
      expect(prefs.items['hdr']!.valueImages, {'DV': _ref2});
      expect(prefs.items.containsKey('unknown_badge'), isFalse);
    });

    test('an unknown preset is classic, JSON text is parsed, and garbage gives the defaults', () {
      expect(_prefs({}, preset: 'neon').preset, 'classic');
      final fromText = SiloOverlayPrefs.parse(
        jsonEncode({
          'version': 2,
          'preset': 'band',
          'items': {
            'year': {'enabled': true},
          },
        }),
      );
      expect(fromText.preset, 'band');
      expect(fromText.items['year']!.enabled, isTrue);
      expect(SiloOverlayPrefs.parse('{not json').preset, 'classic');
      expect(SiloOverlayPrefs.parse(42).items['resolution']!.enabled, isTrue);
    });

    test('a v1 document (badges by id) migrates', () {
      final prefs = SiloOverlayPrefs.parse({
        'resolution': {'enabled': false},
        'year': {'enabled': true, 'position': 'bottom-right'},
      });
      expect(prefs.preset, 'classic');
      expect(prefs.items['resolution']!.enabled, isFalse);
      expect(prefs.items['year']!.enabled, isTrue);
      expect(prefs.items['year']!.position, SiloOverlayPosition.bottomRight);
    });

    test('style overrides outside the contract are dropped', () {
      final style = SiloOverlayStyle.parse({
        'size': 3,
        'shape': 'blob',
        'background': '#112233',
        'textColor': '#ffffff',
        'borderColor': '#ffffff80',
        'borderWidth': 1.5,
        'fontWeight': 'extrabold',
        'shadow': true,
      })!;
      expect(style.size, isNull);
      expect(style.shape, isNull);
      expect(style.background, isNull, reason: 'a background needs 8 hex digits');
      expect(style.textColor, '#ffffff');
      expect(style.borderColor, '#ffffff80');
      expect(style.borderWidth, isNull);
      expect(style.fontWeight, 'extrabold');
      expect(style.shadow, isTrue);
      expect(SiloOverlayStyle.parse({'size': 9}), isNull);
    });
  });

  group('settings', () {
    final config = {
      'enabled': true,
      'defaults': jsonEncode({
        'version': 2,
        'preset': 'vibrant',
        'items': {
          'year': {'enabled': true},
          'resolution': {'image': _ref},
        },
      }),
      'images': [
        {'ref': _ref, 'width': 64, 'height': 32},
      ],
    };

    test("the server's default applies until the profile chooses", () {
      final settled = SiloCardOverlaySettings.settle(const SiloOverlayProfileValues(), config);
      expect(settled.enabled, isTrue);
      expect(settled.prefs.preset, 'vibrant');
      expect(settled.prefs.items['year']!.enabled, isTrue);
      expect(settled.prefs.items['resolution']!.image, _ref);
      expect(settled.images[_ref]!.aspectRatio, 2);
    });

    test("the profile's document and switch win over the server's", () {
      final values = SiloOverlayProfileValues.fromEffective({
        'items': [
          {
            'key': 'ui.card_overlays',
            'source': 'profile',
            'value': {'version': 2, 'preset': 'pill', 'items': {}},
          },
          {'key': 'ui.card_overlays_enabled', 'source': 'profile', 'value': false},
        ],
      });
      final settled = SiloCardOverlaySettings.settle(values, config);
      expect(settled.enabled, isFalse);
      expect(settled.prefs.preset, 'pill');
    });

    test('values from another scope are not the profile choosing', () {
      final values = SiloOverlayProfileValues.fromEffective({
        'items': [
          {'key': 'ui.card_overlays', 'source': 'default', 'value': '{"version":2,"preset":"band","items":{}}'},
          {'key': 'ui.card_overlays_enabled', 'source': 'account', 'value': false},
        ],
      });
      expect(values.document, isNull);
      expect(values.enabled, isNull);
      final settled = SiloCardOverlaySettings.settle(values, {...config, 'enabled': false});
      expect(settled.enabled, isFalse, reason: "the server's switch applies");
      expect(settled.prefs.preset, 'vibrant');
    });

    test('without either answer badges are on in the classic look', () {
      final settled = SiloCardOverlaySettings.settle(null, null);
      expect(settled.enabled, isTrue);
      expect(settled.prefs.preset, 'classic');
    });

    test('images the config does not list are dropped, and a failed one can be removed', () {
      final settled = SiloCardOverlaySettings.settle(
        SiloOverlayProfileValues(
          document: {
            'version': 2,
            'preset': 'classic',
            'items': {
              'resolution': {'image': _ref2},
              'hdr': {
                'valueImages': {'DV': _ref},
              },
            },
          },
        ),
        config,
      );
      expect(settled.prefs.items['resolution']!.image, isNull);
      expect(settled.prefs.items['hdr']!.valueImages, {'DV': _ref});
      final without = settled.withoutImage(_ref);
      expect(without.prefs.items['hdr']!.valueImages, isNull);
      expect(without.images, isEmpty);
    });
  });

  group('labels', () {
    final uhd = _data({
      'overlay_summary': {'resolution': '2160p', 'hdr': 'DV', 'audio': 'Atmos', 'release_type': 'REMUX'},
    });

    test('the combined badge names resolution, dynamic range and audio', () {
      expect(SiloOverlayBadges.label('resolution_hdr_audio', uhd), '4K DV Atmos');
      expect(SiloOverlayBadges.label('resolution_hdr', uhd), '4K DV');
      final hd = _data({
        'overlay_summary': {'resolution': '1080p', 'audio': 'TrueHD'},
      });
      expect(SiloOverlayBadges.label('resolution_hdr_audio', hd), '1080p TrueHD');
      final audioOnly = _data({
        'overlay_summary': {'audio': 'DTS-HD MA'},
      });
      expect(SiloOverlayBadges.label('resolution_hdr_audio', audioOnly), 'DTS-HD MA');
      expect(SiloOverlayBadges.label('resolution_hdr', audioOnly), '');
      final hdrPlus = _data({
        'overlay_summary': {'resolution': '4k', 'hdr': 'HDR10+'},
      });
      expect(SiloOverlayBadges.label('resolution_hdr', hdrPlus), '4K HDR10+');
    });

    test('values read as Silo writes them', () {
      final data = _data({
        'overlay_summary': {'resolution': 'sd', 'multi_audio': true, 'multi_sub': false},
        'rating_imdb': 7.84,
        'rating_tmdb': 6,
        'rating_rt_critic': 93,
        'advisory_age': 16,
        'year': 1995,
        'runtime': 163,
        'original_language': 'en',
        'show_status': 'Returning Series',
        'studios': ['', ' Warner Bros. '],
        'networks': ['HBO'],
      });
      expect(SiloOverlayBadges.label('resolution', data), 'SD');
      expect(SiloOverlayBadges.label('multi_audio', data), 'Multi-Audio');
      expect(SiloOverlayBadges.label('multi_sub', data), '');
      expect(SiloOverlayBadges.label('rating_imdb', data), 'IMDb 7.8');
      expect(SiloOverlayBadges.label('rating_tmdb', data), 'TMDB 6.0');
      expect(SiloOverlayBadges.label('rating_rt', data), 'RT 93%');
      expect(SiloOverlayBadges.label('advisory_age', data), '16+');
      expect(SiloOverlayBadges.label('year', data), '1995');
      expect(SiloOverlayBadges.label('runtime', data), '2h 43m');
      expect(SiloOverlayBadges.label('original_language', data), 'English');
      expect(SiloOverlayBadges.label('show_status', data), 'Returning');
      expect(SiloOverlayBadges.label('studio', data), 'Warner Bros.');
      expect(SiloOverlayBadges.label('network', data), 'HBO');
      expect(SiloOverlayBadges.valueKey('show_status', data), 'Returning');
      expect(SiloOverlayBadges.valueKey('resolution_hdr_audio', uhd), '2160p DV Atmos');
      expect(SiloOverlayBadges.valueKey('year', data), '');
    });

    test('wordmarks replace a label that says the same, and plate puts the source on a chip', () {
      final classic = SiloOverlayLook.of('pill', null); // prefers icons
      final audio = SiloOverlayBadges.badge(
        SiloOverlayRegistry.byId('audio')!,
        uhd,
        classic,
        SiloOverlayPrefs.defaults().items['audio'],
      )!;
      expect(audio.icon, 'atmos');
      final finished = SiloOverlayBadges.finish(audio, classic);
      expect(finished.markText, 'ATMOS');
      expect(finished.text, '');

      final rated = _data({'rating_imdb': 8.25});
      final plate = SiloOverlayLook.of('plate', null);
      final imdb = SiloOverlayBadges.badge(SiloOverlayRegistry.byId('rating_imdb')!, rated, plate, null)!;
      expect(imdb.label, 'IMDb 8.3');
      final onPlate = SiloOverlayBadges.finish(imdb, plate);
      expect(onPlate.chip, 'IMDB');
      expect(onPlate.text, '8.3');
      expect(onPlate.scoreOnly, isTrue);
      final onClassic = SiloOverlayBadges.finish(imdb, SiloOverlayLook.of('classic', null));
      expect(onClassic.chip, isNull);
      expect(onClassic.text, 'IMDB 8.3');
    });

    test('a badge hides when the card has no value, and icons follow the look and the override', () {
      final classic = SiloOverlayLook.of('classic', null);
      final empty = SiloOverlayData.empty;
      expect(SiloOverlayBadges.badge(SiloOverlayRegistry.byId('resolution')!, empty, classic, null), isNull);
      final hd = _data({
        'overlay_summary': {'resolution': '1080p'},
      });
      final plain = SiloOverlayBadges.badge(SiloOverlayRegistry.byId('resolution')!, hd, classic, null)!;
      expect(plain.icon, isNull, reason: 'classic prefers no icons');
      final forced = SiloOverlayBadges.badge(
        SiloOverlayRegistry.byId('resolution')!,
        hd,
        classic,
        const SiloOverlayItemConfig(enabled: true, position: SiloOverlayPosition.topLeft, showIcon: true),
      )!;
      expect(forced.icon, 'monitor');
    });
  });

  group('placement', () {
    final data = _data({
      'overlay_summary': {
        'resolution': '2160p',
        'hdr': 'HDR10',
        'audio': 'Atmos',
        'audio_channels': '7.1',
        'video_codec': 'HEVC',
        'release_type': 'WEB-DL',
        'container': 'MKV',
      },
      'year': 2024,
      'rating_imdb': 7,
      'rating_tmdb': 7,
      'rating_rt_critic': 80,
      'rating_rt_audience': 70,
      'content_rating': 'PG-13',
    });
    final look = SiloOverlayLook.of('classic', null);

    test('enabled badges sit at their positions in the document order, then the registry order', () {
      final prefs = _prefs({}, order: ['audio', 'resolution']);
      final resolved = SiloOverlayBadges.resolve(prefs, data, look);
      expect(_ids(resolved[SiloOverlayPosition.topLeft]!), ['audio', 'resolution', 'hdr']);
      expect(_ids(resolved[SiloOverlayPosition.bottomLeft]!), ['release_type']);
      expect(resolved[SiloOverlayPosition.leftEdge], isEmpty);
    });

    test('a corner draws three badges and a rail four', () {
      final prefs = _prefs({
        'audio_channels': {'enabled': true},
        'video_codec': {'enabled': true},
        for (final id in ['rating_imdb', 'rating_tmdb', 'rating_rt', 'rating_rt_audience', 'content_rating'])
          id: {'enabled': true, 'position': 'left-edge'},
      });
      final resolved = SiloOverlayBadges.resolve(prefs, data, look);
      expect(_ids(resolved[SiloOverlayPosition.topLeft]!), ['resolution', 'hdr', 'audio']);
      expect(_ids(resolved[SiloOverlayPosition.leftEdge]!), [
        'rating_imdb',
        'rating_tmdb',
        'rating_rt',
        'rating_rt_audience',
      ]);
    });

    test('a badge without a value does not take a capped slot', () {
      final sparse = _data({
        'overlay_summary': {'resolution': '720p', 'video_codec': 'H.264', 'audio_channels': '5.1'},
      });
      final prefs = _prefs({
        'audio_channels': {'enabled': true},
        'video_codec': {'enabled': true},
      });
      final resolved = SiloOverlayBadges.resolve(prefs, sparse, look);
      expect(_ids(resolved[SiloOverlayPosition.topLeft]!), ['resolution', 'audio_channels', 'video_codec']);
    });

    test('combined badges hide the badges they already show, and give them back when off', () {
      final combined = _prefs({
        'resolution_hdr_audio': {'enabled': true},
        'resolution_hdr': {'enabled': true},
      });
      expect(SiloOverlayRegistry.isSuppressed('resolution', combined), isTrue);
      expect(SiloOverlayRegistry.isSuppressed('resolution_hdr', combined), isTrue);
      final resolved = SiloOverlayBadges.resolve(combined, data, look);
      expect(_ids(resolved[SiloOverlayPosition.topLeft]!), ['resolution_hdr_audio']);
      expect(resolved[SiloOverlayPosition.topLeft]!.single.label, '4K HDR Atmos');

      final pairOnly = _prefs({
        'resolution_hdr': {'enabled': true},
      });
      expect(_ids(SiloOverlayBadges.resolve(pairOnly, data, look)[SiloOverlayPosition.topLeft]!), [
        'resolution_hdr',
        'audio',
      ]);
      expect(SiloOverlayRegistry.isSuppressed('resolution', SiloOverlayPrefs.defaults()), isFalse);
    });

    test('bottom rows line the shorter corner up with the bottom', () {
      final rows = SiloOverlayBadges.bottomRows(['a', 'b', 'c'], ['x']);
      expect(rows, [('a', null), ('b', null), ('c', 'x')]);
      expect(SiloOverlayBadges.bottomRows<String>([], []), isEmpty);
    });

    test('a band keeps the marks that fit whole, at least one', () {
      expect(SiloOverlayBadges.bandFit([40, 40, 40], 100, 7, 1), 2);
      expect(SiloOverlayBadges.bandFit([400], 100, 7, 1), 1);
      expect(SiloOverlayBadges.bandFit([], 100, 7, 1), 0);
    });
  });

  group('looks', () {
    test('presets carry the web lengths and size scales them', () {
      final classic = SiloOverlayLook.of('classic', null);
      expect(classic.fontSize, 10);
      expect(classic.radius, -1);
      final band = SiloOverlayLook.of('band', null);
      expect(band.band, isTrue);
      expect(band.flushRails, isFalse);
      final scaled = SiloOverlayLook.of('classic', SiloOverlayStyle.parse({'size': 2, 'shape': 'square'}));
      expect(scaled.fontSize, 20);
      expect(scaled.padX, 16);
      expect(scaled.radius, 2);
    });

    test('accents paint as each preset says', () {
      final classic = SiloOverlayPaint.of(SiloOverlayLook.of('classic', null), null);
      expect(classic.fill, 0x99000000);
      expect(classic.border, 0x26FFFFFF);
      final vibrant = SiloOverlayPaint.of(SiloOverlayLook.of('vibrant', null), '#f5c518');
      expect(vibrant.fill, 0xFFF5C518);
      expect(vibrant.text, 0xFFFFFFFF);
      final square = SiloOverlayPaint.of(SiloOverlayLook.of('square', null), '#fa320a');
      expect(square.accentLeft, 0xFFFA320A);
      expect(square.text, 0xFFFA320A);
      final mixed = SiloOverlayPaint.of(SiloOverlayLook.of('classic', null), '#ffffff');
      // color-mix(#ffffff 28%, #00000099): alpha .28 + .6 * .72 = .712
      expect((mixed.fill! >> 24) & 0xFF, closeTo(0.712 * 255, 1));
    });

    test('a solid style background picks a readable text colour', () {
      final look = SiloOverlayLook.of('classic', SiloOverlayStyle.parse({'background': '#ffffffff'}));
      expect(look.solid, 0xFFFFFFFF);
      expect(look.textShadow, isNull);
      expect(SiloOverlayPaint.of(look, null).text, 0xFF000000);
      expect(siloOverlayReadableOn(0xFF000000), 0xFFFFFFFF);
    });
  });

  group('poster layout (Silo Android #882)', () {
    test('a stored top-right badge moves to the right-edge rail; the corner holds no badge', () {
      expect(SiloOverlayPosition.fromWire('top-right'), SiloOverlayPosition.rightEdge);
      expect(SiloOverlayPosition.values.map((p) => p.wire), isNot(contains('top-right')));
      final prefs = _prefs({
        'rating_imdb': {'enabled': true, 'position': 'top-right'},
      });
      expect(prefs.items['rating_imdb']!.position, SiloOverlayPosition.rightEdge);
      final resolved = SiloOverlayBadges.resolve(
        prefs,
        _data({'rating_imdb': 7.5}),
        SiloOverlayLook.of('classic', null),
      );
      expect(_ids(resolved[SiloOverlayPosition.rightEdge]!), ['rating_imdb']);
      expect(SiloOverlayPosition.rightEdge.isRail, isTrue);
      expect(SiloCardOverlays.maxCorner, 3);
      expect(SiloCardOverlays.maxRail, 4);
    });

    test('every corner stops at three and every rail at four', () {
      final full = _data({
        'overlay_summary': {
          'resolution': '2160p',
          'hdr': 'HDR10',
          'audio': 'Atmos',
          'audio_channels': '7.1',
          'video_codec': 'HEVC',
          'container': 'MKV',
          'release_type': 'WEB-DL',
          'edition': 'IMAX',
          'aspect_ratio': '2.39',
          'multi_audio': true,
          'multi_sub': true,
        },
        'year': 2024,
        'runtime': 120,
        'rating_imdb': 7,
        'rating_tmdb': 7,
        'rating_rt_critic': 80,
        'rating_rt_audience': 70,
        'content_rating': 'PG-13',
        'studios': ['A24'],
      });
      final ids = ['container', 'edition', 'year', 'runtime'];
      final prefs = _prefs({
        for (final id in ids) id: {'enabled': true},
        for (final id in ['aspect_ratio', 'multi_audio', 'multi_sub', 'content_rating']) id: {'enabled': true},
        for (final id in ['rating_imdb', 'rating_tmdb', 'rating_rt', 'rating_rt_audience', 'studio'])
          id: {'enabled': true, 'position': 'right-edge'},
      });
      final resolved = SiloOverlayBadges.resolve(prefs, full, SiloOverlayLook.of('classic', null));
      expect(resolved[SiloOverlayPosition.bottomLeft]!, hasLength(3));
      expect(resolved[SiloOverlayPosition.bottomRight]!, hasLength(3));
      expect(_ids(resolved[SiloOverlayPosition.rightEdge]!), [
        'rating_imdb',
        'rating_tmdb',
        'rating_rt',
        'rating_rt_audience',
      ]);
    });

    test('insets: a poster scales by width over 185, a wide card draws at 1, a progress bar lifts the bottom', () {
      final poster = SiloOverlayLayoutMath.insets(width: 370, wide: false, progress: false);
      expect(poster.k, 2);
      expect(poster.side, 16);
      expect(poster.bottom, 16);
      // 8 inset + 22 status + 8 gap, scaled.
      expect(poster.topRight, 76);
      final lifted = SiloOverlayLayoutMath.insets(width: 185, wide: false, progress: true);
      expect(lifted.bottom, 16, reason: 'a poster with a progress bar lifts its bottom row too');
      final wide = SiloOverlayLayoutMath.insets(width: 320, wide: true, progress: true);
      expect(wide.k, 1);
      expect(wide.side, 8);
      expect(wide.bottom, 16);
      expect(wide.topRight, 38);
    });

    ({List<SiloBadgeOffset> left, List<SiloBadgeOffset> right, double height}) rows(
      List<(double, double)> left,
      List<(double, double)> right, {
      double available = 169,
    }) => SiloOverlayLayoutMath.bottomRows(
      [for (final (w, h) in left) (w: w, h: h)],
      [for (final (w, h) in right) (w: w, h: h)],
      available: available,
      gap: 8,
      stackGap: 4,
    );

    // Hand-worked cases from the web's CSS, as Silo Android's OverlayLayoutMathTest has them.
    test('a pair that fits shares one row with the right badge at the end', () {
      final r = rows([(60, 14)], [(40, 14)]);
      expect(r.height, 14);
      expect(r.left.single, (x: 0.0, y: 0.0));
      expect(r.right.single, (x: 129.0, y: 0.0));
      expect(rows([(100, 14)], [(61, 14)]).right.single.y, 0, reason: 'an exact fit stays on one row');
    });

    test('a pair one pixel too wide wraps the right badge onto a line of its own below', () {
      final r = rows([(100, 14)], [(62, 14)]);
      expect(r.left.single, (x: 0.0, y: 0.0));
      expect(r.right.single, (x: 107.0, y: 18.0));
      expect(r.height, 32);
      final full = rows([(169, 14)], [(30, 14)]);
      expect(full.right.single, (x: 139.0, y: 18.0));
      expect(SiloOverlayLayoutMath.fitsOnOneLine(100, 61, 169, 8), isTrue);
      expect(SiloOverlayLayoutMath.fitsOnOneLine(100, 62, 169, 8), isFalse);
    });

    test('levels count from the bottom, and a wrap at one level leaves the others alone', () {
      final r = rows([(50, 10), (50, 10), (50, 10)], [(40, 10)]);
      expect([for (final o in r.left) o.y], [0, 14, 28]);
      expect(r.right.single.y, 28);
      expect(r.height, 38);
      final mixed = rows([(150, 10), (40, 10)], [(40, 10), (40, 10)]);
      expect([for (final o in mixed.left) o.y], [0, 28]);
      expect([for (final o in mixed.right) o.y], [14, 28]);
      expect(mixed.height, 38);
    });

    test('badges on one line align to its bottom; a right corner alone sits at the end', () {
      final r = rows([(40, 20)], [(40, 12)]);
      expect(r.left.single.y, 0);
      expect(r.right.single.y, 8);
      expect(r.height, 20);
      final alone = rows([], [(30, 10), (50, 10)]);
      expect([for (final o in alone.right) o.x], [139, 119]);
      expect([for (final o in alone.right) o.y], [0, 14]);
      expect(rows([], []).height, 0);
    });

    test("the watch-status count is the label plus 0.4 em a side and its border, never narrower than tall", () {
      expect(SiloOverlayLayoutMath.countWidth(5, 1), 22);
      // 30 + 11 * 0.8 + 2
      expect(SiloOverlayLayoutMath.countWidth(30, 1), closeTo(40.8, 1e-9));
      expect(SiloOverlayLayoutMath.countWidth(30, 2), closeTo(49.6, 1e-9));
    });
  });

  group('presets (the web numbers)', () {
    test('each preset has its font, padding, radius, border, icon, gap, tracking and accent strategy', () {
      final table = {
        // id: fontSize, padX, padY, radius, border, iconSize, iconGap, stackGap, tracking, weight, preferIcon
        'minimal': (9.0, 4.0, 0.0, 8.0, 0.0, 10.0, 4.0, 2.0, 0.1, 600, false, SiloAccentStrategy.text),
        'classic': (10.0, 8.0, 2.0, -1.0, 1.0, 11.0, 4.0, 4.0, 0.025, 600, false, SiloAccentStrategy.background),
        'vibrant': (10.0, 8.0, 2.0, 10.0, 0.0, 12.0, 4.0, 4.0, 0.025, 700, true, SiloAccentStrategy.background),
        'pill': (10.0, 10.0, 4.0, -1.0, 1.0, 12.0, 4.0, 4.0, 0.025, 600, true, SiloAccentStrategy.background),
        'square': (9.0, 6.0, 2.0, 8.0, 0.0, 10.0, 4.0, 2.0, 0.1, 700, false, SiloAccentStrategy.border),
        'plate': (12.0, 7.0, 4.0, 6.0, 1.0, 13.0, 5.0, 4.0, 0.025, 800, true, SiloAccentStrategy.border),
        'band': (12.5, 0.0, 1.0, 0.0, 0.0, 13.0, 3.0, 7.0, 0.025, 800, false, SiloAccentStrategy.text),
      };
      expect(table.keys, SiloCardOverlays.presetIds);
      for (final MapEntry(key: id, value: v) in table.entries) {
        final look = SiloOverlayLook.of(id, null);
        expect(
          (
            look.fontSize,
            look.padX,
            look.padY,
            look.radius,
            look.borderWidth,
            look.iconSize,
            look.iconGap,
            look.stackGap,
            look.letterSpacingEm,
            look.weight,
            look.preferIcon,
            look.strategy,
          ),
          v,
          reason: id,
        );
      }
      expect(SiloOverlayLook.of('plate', null).sourceChips, isTrue);
      expect(SiloOverlayLook.of('square', null).accentLeft, 2);
      expect(SiloOverlayLook.of('nonsense', null).id, 'classic');
    });

    test('the style layer scales lengths, frames bare text and keeps the tracking', () {
      final minimal = SiloOverlayLook.of('minimal', SiloOverlayStyle.parse({'size': 1.5, 'borderWidth': 1}));
      expect(minimal.fontSize, 13.5);
      expect(minimal.padX, closeTo(13.5 * 0.6, 1e-9), reason: 'a framed badge gets at least 0.6 em of padding');
      expect(minimal.padY, closeTo(13.5 * 0.2, 1e-9));
      expect(minimal.letterSpacingEm, 0.1);
      expect(minimal.borderWidth, 1);
      final shadowed = SiloOverlayLook.of('classic', SiloOverlayStyle.parse({'shadow': true}));
      expect(shadowed.boxShadow!.blur, 6);
      expect(SiloOverlayLook.of('plate', SiloOverlayStyle.parse({'shadow': false})).boxShadow, isNull);
    });

    test('a CSS blur length converts to the same Gaussian in Flutter', () {
      expect(siloCssBlurRadius(0), 0);
      expect(siloCssBlurRadius(1), 0);
      expect(siloCssBlurRadius(6), closeTo(2.5 / 0.57735, 1e-9));
    });
  });

  group('web parity details', () {
    test('values keep the spelling the API sent for value-image matches', () {
      final data = _data({
        'show_status': 'Returning Series ',
        'content_rating': ' ',
        'overlay_summary': {'resolution': '2160p'},
      });
      expect(data.text('show_status'), 'Returning Series ');
      expect(SiloOverlayBadges.valueKey('show_status', data), 'Returning Series ');
      expect(data.text('content_rating'), '', reason: 'a blank value is no value');
    });

    test('a v2 document whose items came as a list still keeps its preset', () {
      final prefs = SiloOverlayPrefs.parse({'preset': 'band', 'items': []});
      expect(prefs.preset, 'band');
    });

    test('an uploaded image in the mark\'s place still drops a label the wordmark spells', () {
      final pill = SiloOverlayLook.of('pill', null);
      final badge = SiloOverlayBadges.badge(
        SiloOverlayRegistry.byId('audio')!,
        _data({
          'overlay_summary': {'audio': 'Atmos'},
        }),
        pill,
        SiloOverlayItemConfig(enabled: true, position: SiloOverlayPosition.topLeft, image: _ref),
      )!;
      final finished = SiloOverlayBadges.finish(badge, pill, withImage: true);
      expect(finished.markText, isNull);
      expect(finished.text, '');
    });
  });

  test('episodes left show only on a started, unfinished series or season', () {
    expect(siloEpisodesLeft(played: false, watched: 3, unplayed: 5), 5);
    expect(siloEpisodesLeft(played: false, watched: 0, unplayed: 8), 0);
    expect(siloEpisodesLeft(played: true, watched: 3, unplayed: 5), 0);
    expect(siloEpisodesLeft(played: false, watched: 8, unplayed: 0), 0);
  });

  group('store', () {
    setUp(SiloCardOverlayStore.resetKnownForTesting);

    test('concurrent reads share one request each, and a 404 config draws the built-in document', () async {
      var configReads = 0;
      var valueReads = 0;
      final gate = Completer<void>();
      final store = SiloCardOverlayStore(
        cacheKey: 'srv/u/p',
        readConfig: () async {
          configReads++;
          await gate.future;
          return null;
        },
        readValues: () async {
          valueReads++;
          return {'items': []};
        },
      );
      final a = store.ensureLoaded();
      final b = store.refresh(force: true);
      final c = store.ensureLoaded();
      expect(store.value, isNull);
      gate.complete();
      await Future.wait([a, b, c]);
      expect(configReads, 1);
      expect(valueReads, 1);
      expect(store.value!.enabled, isTrue);
      expect(store.value!.prefs.preset, 'classic');
      // A refresh straight after is skipped.
      await store.refresh();
      expect(configReads, 1);
    });

    test('a failed read keeps what applies, and a rebuilt store starts from the last answer', () async {
      var fail = false;
      SiloCardOverlayStore build() => SiloCardOverlayStore(
        cacheKey: 'srv/u/p',
        minRefreshInterval: Duration.zero,
        readConfig: () async => {'enabled': false},
        readValues: () async {
          if (fail) throw Exception('offline');
          return {'items': []};
        },
      );
      final store = build();
      await store.ensureLoaded();
      final first = store.value;
      expect(first!.enabled, isFalse);
      fail = true;
      await store.refresh(force: true);
      expect(store.value, same(first));
      expect(build().value, same(first));
    });

    test('the same answer again does not notify; a changed one does', () async {
      var enabled = true;
      final store = SiloCardOverlayStore(
        cacheKey: 'srv/u/p2',
        minRefreshInterval: Duration.zero,
        readConfig: () async => {'enabled': enabled},
        readValues: () async => null,
      );
      var notified = 0;
      store.addListener(() => notified++);
      await store.refresh();
      await store.refresh();
      expect(notified, 1);
      enabled = false;
      await store.refresh();
      expect(notified, 2);
      expect(store.value!.enabled, isFalse);
    });

    test('an uploaded image that fails drops out of the settings', () async {
      final store = SiloCardOverlayStore(
        cacheKey: 'srv/u/p3',
        readConfig: () async => {
          'enabled': true,
          'images': [
            {'ref': _ref, 'width': 10, 'height': 10},
          ],
          'defaults': jsonEncode({
            'version': 2,
            'preset': 'classic',
            'items': {
              'resolution': {'image': _ref},
            },
          }),
        },
        readValues: () async => null,
      );
      await store.ensureLoaded();
      expect(store.value!.prefs.items['resolution']!.image, _ref);
      store.imageFailed(_ref);
      await Future<void>.delayed(Duration.zero);
      expect(store.value!.prefs.items['resolution']!.image, isNull);
    });

    test('a failed uploaded image is tried again by a read after the retry delay', () async {
      var now = DateTime(2026, 11, 12, 20);
      await withClock(Clock(() => now), () async {
        final store = SiloCardOverlayStore(
          cacheKey: 'srv/u/p3b',
          readConfig: () async => {
            'enabled': true,
            'images': [
              {'ref': _ref, 'width': 10, 'height': 10},
            ],
            'defaults': jsonEncode({
              'version': 2,
              'preset': 'classic',
              'items': {
                'resolution': {'image': _ref},
              },
            }),
          },
          readValues: () async => null,
        );
        await store.ensureLoaded();
        store.imageFailed(_ref);
        await Future<void>.delayed(Duration.zero);
        expect(store.value!.prefs.items['resolution']!.image, isNull);

        // Too soon: the same settings stay without the image.
        now = now.add(const Duration(minutes: 1));
        await store.refresh(force: true);
        expect(store.value!.prefs.items['resolution']!.image, isNull);

        now = now.add(SiloCardOverlayStore.failedImageRetry);
        await store.refresh(force: true);
        expect(store.value!.prefs.items['resolution']!.image, _ref);

        // A second failure drops it again.
        store.imageFailed(_ref);
        await Future<void>.delayed(Duration.zero);
        expect(store.value!.prefs.items['resolution']!.image, isNull);
        store.dispose();
      });
    });

    test('the remembered settings are bounded and forgotten for a removed connection', () async {
      for (var i = 0; i < SiloCardOverlayStore.maxKnown + 10; i++) {
        final store = SiloCardOverlayStore(
          cacheKey: 'srv/u/p$i',
          readConfig: () async => {'enabled': true},
          readValues: () async => null,
        );
        await store.ensureLoaded();
        store.dispose();
      }
      expect(SiloCardOverlayStore.knownCountForTesting, SiloCardOverlayStore.maxKnown);
      final last = 'srv/u/p${SiloCardOverlayStore.maxKnown + 9}';
      SiloCardOverlayStore build(String key) =>
          SiloCardOverlayStore(cacheKey: key, readConfig: () async => null, readValues: () async => null);
      expect(build(last).value, isNotNull);
      expect(build('srv/u/p0').value, isNull, reason: 'the oldest fell out');
      SiloCardOverlayStore.forget(last);
      expect(build(last).value, isNull);
    });

    test('dispose tells listeners once and is idempotent', () {
      final store = SiloCardOverlayStore(
        cacheKey: 'srv/u/d',
        readConfig: () async => null,
        readValues: () async => null,
      );
      var notified = 0;
      store.addListener(() => notified++);
      store.dispose();
      store.dispose();
      expect(notified, 1);
      expect(store.isDisposed, isTrue);
    });
  });
}
