// Runs the fake IPTV provider used by the IPTV tests, for trying Plezilo's
// IPTV screens by hand without a real provider.
//
//   dart run scripts/iptv_fake_server.dart [--port 8899] [--channels 50]
//
// Then add an IPTV source in Plezilo with one of:
//   M3U:     http://127.0.0.1:8899/playlist.m3u   (guide: …/epg.xml.gz)
//   Xtream:  server http://127.0.0.1:8899, username demo, password secret
// (From an Android emulator the host is 10.0.2.2.)
import 'dart:io';

import '../test/services/iptv/fake_iptv_server.dart';

Future<void> main(List<String> args) async {
  var port = 8899;
  var channels = 12;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.parse(args[i + 1]);
    if (args[i] == '--channels') channels = int.parse(args[i + 1]);
  }
  final server = await FakeIptvServer(channelCount: channels).start(port: port);
  stdout.writeln('Fake IPTV provider on ${server.base} (Ctrl-C to stop)');
  stdout.writeln('  M3U:    ${server.base}/playlist.m3u');
  stdout.writeln('  Xtream: ${server.base}  user demo  password secret');
  await ProcessSignal.sigint.watch().first;
  await server.close();
}
