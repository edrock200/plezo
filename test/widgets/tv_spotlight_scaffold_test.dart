import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/widgets/tv_spotlight_scaffold.dart';
import '../test_helpers/media_items.dart';

MediaItem _item(String id) => testMediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: id);

MediaHub _hub(String id, List<MediaItem> items) =>
    MediaHub(id: id, title: id, type: 'movie', size: items.length, items: items);

void main() {
  test('spotlight controller cancels an intermediate debounced selection', () async {
    final first = _item('first');
    final second = _item('second');
    final controller = TvSpotlightController(settleDelay: const Duration(milliseconds: 10));
    addTearDown(controller.dispose);
    controller.value = first;

    controller.select(second);
    controller.select(first);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.value, same(first));
  });

  test('spotlight controller resolves valid selection or first hub item', () {
    final first = _item('first');
    final second = _item('second');
    final controller = TvSpotlightController(settleDelay: Duration.zero);
    addTearDown(controller.dispose);
    final hubs = [
      _hub('one', [first]),
      _hub('two', [second]),
    ];

    expect(controller.resolve(hubs), same(first));
    controller.select(second);
    expect(controller.resolve(hubs), same(second));

    controller.value = _item('removed');
    expect(controller.resolve(hubs), same(first));
  });

  test('spotlight controller resolves the latest item instance for a retained selection', () {
    final stale = _item('same');
    final refreshed = testMediaItem(id: 'same', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Updated');
    final controller = TvSpotlightController(settleDelay: Duration.zero);
    addTearDown(controller.dispose);
    controller.value = stale;

    expect(
      controller.resolve([
        _hub('one', [refreshed]),
      ]),
      same(refreshed),
    );
  });

  group('Silo collection cards (rows of collections)', () {
    MediaItem collection(String id, {String? art}) => testMediaItem(
      id: id,
      backend: MediaBackend.silo,
      kind: MediaKind.collection,
      title: id,
      thumbPath: 'https://cdn.example.com/$id.jpg',
      artPath: art,
      leafCount: 3,
    );

    test('a card with a backdrop takes the spotlight; one without leaves it as it was', () {
      final title = _item('title');
      final withBackdrop = collection('heists', art: 'https://cdn.example.com/b.jpg?sig=1');
      final bare = collection('date-night');
      final controller = TvSpotlightController(settleDelay: Duration.zero);
      addTearDown(controller.dispose);
      final hubs = [
        _hub('titles', [title]),
        _hub('picks', [bare, withBackdrop]),
      ];

      controller.select(title);
      controller.select(bare);
      expect(controller.value, same(title));
      expect(controller.resolve(hubs), same(title));

      controller.select(withBackdrop);
      expect(controller.resolve(hubs), same(withBackdrop));
    });

    test('the fallback skips collection cards without a backdrop', () {
      final bare = collection('date-night');
      final withBackdrop = collection('heists', art: 'https://cdn.example.com/b.jpg');
      final title = _item('title');
      final controller = TvSpotlightController(settleDelay: Duration.zero);
      addTearDown(controller.dispose);

      expect(
        controller.resolve([
          _hub('picks', [bare, withBackdrop]),
          _hub('titles', [title]),
        ]),
        same(withBackdrop),
      );
      expect(
        controller.resolve([
          _hub('picks', [bare]),
          _hub('titles', [title]),
        ]),
        same(title),
      );
      expect(
        controller.resolve([
          _hub('picks', [bare]),
        ]),
        isNull,
      );
    });

    test('other backends\' collections are unchanged', () {
      final plexCollection = testMediaItem(id: 'p', backend: MediaBackend.plex, kind: MediaKind.collection);
      expect(TvSpotlightController.takesSpotlight(plexCollection), isTrue);
      expect(TvSpotlightController.takesSpotlight(_item('movie')), isTrue);
    });
  });
}
