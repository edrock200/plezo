import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/screens/video_player/live_channel_zapper.dart';

void main() {
  final channels = [
    for (final n in ['1', '2', '5', '10', '101', '102', '250']) LiveTvChannel(key: 'c$n', title: 'Ch $n', number: n),
  ];

  LiveChannelZapper zapper({int current = 0, List<int>? tuned, bool Function(int)? accept}) => LiveChannelZapper(
    channels: channels,
    currentIndex: current,
    onZap: (i) async {
      tuned?.add(i);
      return accept?.call(i) ?? true;
    },
  );

  test('channel up and down step through the list and wrap around', () async {
    final tuned = <int>[];
    final z = zapper(tuned: tuned);
    await z.step(1);
    expect(z.currentIndex, 1);
    await z.step(-1);
    await z.step(-1);
    expect(z.currentIndex, channels.length - 1, reason: 'down from the first wraps to the last');
    await z.step(1);
    expect(z.currentIndex, 0);
    expect(tuned, [1, 0, 6, 0]);
  });

  test('a refused zap keeps the current channel', () async {
    final z = zapper(accept: (_) => false);
    expect(await z.step(1), isFalse);
    expect(z.currentIndex, 0);
    expect(z.previousIndex, isNull);
  });

  test('last-channel recall goes back and forth', () async {
    final z = zapper();
    await z.tuneIndex(4);
    expect(z.previousIndex, 0);
    await z.recall();
    expect(z.currentIndex, 0);
    await z.recall();
    expect(z.currentIndex, 4);
  });

  test('exact numbers win over prefixes; leading zeros are ignored', () {
    expect(LiveChannelZapper.indexForNumber(channels, '10'), 3);
    expect(LiveChannelZapper.indexForNumber(channels, '010'), 3);
    expect(LiveChannelZapper.indexForNumber(channels, '25'), 6, reason: 'prefix of 250');
    expect(LiveChannelZapper.indexForNumber(channels, '9'), isNull);
    expect(LiveChannelZapper.indexForNumber(channels, ''), isNull);
  });

  test('digits wait for the timeout, then tune the match', () {
    fakeAsync((async) {
      final tuned = <int>[];
      final z = zapper(tuned: tuned);
      z.digit(1);
      z.digit(0);
      async.elapse(const Duration(milliseconds: 1000));
      expect(z.pendingDigits, '10');
      z.digit(1);
      expect(z.pendingMatch?.number, '101');
      async.elapse(const Duration(milliseconds: 1000));
      expect(tuned, isEmpty, reason: 'the timer restarts on every digit');
      async.elapse(const Duration(milliseconds: 900));
      expect(tuned, [4]);
      expect(z.pendingDigits, isEmpty);
    });
  });

  test('a full entry commits at once; OK commits early; no match is reported', () async {
    final z = LiveChannelZapper(channels: channels, currentIndex: 0, onZap: (_) async => true, maxDigits: 3);
    expect(await z.digit(1), isNull);
    expect(await z.digit(0), isNull);
    expect(await z.digit(2), isA<ZapToIndex>().having((t) => t.index, 'index', 5));
    await z.digit(2);
    expect(await z.commit(), isA<ZapToIndex>().having((t) => t.index, 'index', 1));
    await z.digit(7);
    expect(await z.commit(), isA<ZapNoMatch>().having((t) => t.digits, 'digits', '7'));
    z.cancelEntry();
  });

  test('a lone 0 recalls the previous channel when no channel is 0', () async {
    final z = zapper();
    await z.tuneIndex(2);
    await z.digit(0);
    final result = await z.commit();
    expect(result, isA<ZapToIndex>().having((t) => t.index, 'index', 0));
    expect(z.currentIndex, 0);
  });

  test('the player zapping by itself is followed', () {
    final z = zapper();
    z.syncCurrent(3);
    expect(z.currentIndex, 3);
    expect(z.previousIndex, 0);
  });
}
