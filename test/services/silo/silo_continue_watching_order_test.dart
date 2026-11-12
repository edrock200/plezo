import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/silo/silo_client.dart';

MediaItem _row(String id, {int? viewed, int? added}) =>
    MediaItem.silo(id: id, kind: MediaKind.episode, lastViewedAt: viewed, addedAt: added);

List<String> _shelfOrder(List<MediaItem> rows) =>
    ([...rows]..sort((a, b) => b.recencySortKey.compareTo(a.recencySortKey))).map((r) => r.id).toList();

void main() {
  group('Silo Continue Watching keeps the server order', () {
    test('next-up rows without a watch time stay where Silo put them', () {
      // Silo: resumable A (watched most recently), next-up B (no time, an old
      // episode), resumable C, next-up D (a brand-new episode).
      final rows = [_row('a', viewed: 1000), _row('b', added: 10), _row('c', viewed: 900), _row('d', added: 5000)];
      expect(_shelfOrder(rows), ['d', 'a', 'c', 'b'], reason: 'the plain recency sort scatters next-up rows');
      expect(_shelfOrder(SiloClient.continueWatchingInServerOrder(rows)), ['a', 'b', 'c', 'd']);
    });

    test('a next-up row first in the list goes first', () {
      final rows = [_row('next', added: 1), _row('resume', viewed: 800)];
      expect(_shelfOrder(SiloClient.continueWatchingInServerOrder(rows)), ['next', 'resume']);
    });

    test('rows without any time keep their order (no ties for the unstable sort)', () {
      final rows = [for (var i = 0; i < 12; i++) _row('r$i')];
      final ordered = SiloClient.continueWatchingInServerOrder(rows, now: 5000);
      expect(_shelfOrder(ordered), [for (var i = 0; i < 12; i++) 'r$i']);
      expect(ordered.first.recencySortKey, 5000);
    });

    test('rows keep their own watch time when it already falls', () {
      final ordered = SiloClient.continueWatchingInServerOrder([_row('a', viewed: 300), _row('b', viewed: 200)]);
      expect([for (final r in ordered) r.recencySortKey], [300, 200]);
      expect(ordered.first.lastViewedAt, 300, reason: 'the watch time itself is unchanged');
    });
  });
}
