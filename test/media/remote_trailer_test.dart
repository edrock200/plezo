import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/remote_trailer.dart';

MediaItem _extra(String id) => MediaItem.silo(id: id, kind: MediaKind.clip, title: id);

RemoteTrailer _video(String key, {String site = 'YouTube', String kind = 'trailer'}) =>
    RemoteTrailer(site: site, key: key, kind: kind);

void main() {
  group('buildExtrasRail (port of Silo trailerRailEntries)', () {
    test('local extras come first, then YouTube videos, each in server order', () {
      final rail = buildExtrasRail([_extra('extra:1'), _extra('extra:2')], [_video('a'), _video('b')]);
      expect(rail.map((e) => e.key), ['local:extra:1', 'local:extra:2', 'remote:youtube:a', 'remote:youtube:b']);
      expect(rail.first, isA<LocalExtraEntry>());
      expect((rail.last as RemoteTrailerEntry).trailer.key, 'b');
    });

    test('other sites and blank keys are dropped', () {
      final rail = buildExtrasRail(const [], [_video('v', site: 'Vimeo'), _video('  '), _video('ok', site: 'youtube')]);
      expect(rail.map((e) => e.key), ['remote:youtube:ok']);
    });

    test('duplicates keep their first position; namespaces keep local and remote apart', () {
      final rail = buildExtrasRail(
        [_extra('abc'), _extra('abc'), _extra('x')],
        [_video('abc'), _video('abc', site: 'YOUTUBE'), _video('y')],
      );
      expect(rail.map((e) => e.key), ['local:abc', 'local:x', 'remote:youtube:abc', 'remote:youtube:y']);
    });

    test('empty inputs give an empty rail', () {
      expect(buildExtrasRail(const [], const []), isEmpty);
    });
  });

  group('primaryRemoteTrailer', () {
    test('prefers the first YouTube trailer, then a teaser', () {
      expect(primaryRemoteTrailer([_video('t', kind: 'teaser'), _video('a', kind: 'Trailer')])?.key, 'a');
      expect(primaryRemoteTrailer([_video('f', kind: 'featurette'), _video('t', kind: 'teaser')])?.key, 't');
    });

    test('never picks other sites, blank keys or non-trailer kinds', () {
      expect(primaryRemoteTrailer([_video('v', site: 'Vimeo'), _video(' ')]), isNull);
      expect(primaryRemoteTrailer([_video('c', kind: 'clip')]), isNull);
    });
  });

  test('YouTube thumbnails use the hqdefault still', () {
    expect(_video('dQw4w9WgXcQ').thumbnailUrl, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
  });

  test('extra kinds have readable labels', () {
    expect(extraKindLabel('trailer'), 'Trailer');
    expect(extraKindLabel('behind-the-scenes'), 'Behind the Scenes');
    expect(extraKindLabel('deleted_scene'), 'Deleted Scene');
    expect(extraKindLabel('short_film'), 'Short Film');
    expect(extraKindLabel(''), 'Extra');
  });
}
