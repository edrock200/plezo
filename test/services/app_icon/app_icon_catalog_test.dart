import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/app_icon/app_icon_catalog.dart';

/// The catalog ids are the platform names devices persist. Plezilo ships no
/// alternate icons (Plezy's are the Plezy project's trademark), so the catalog
/// holds only the default and no platform may declare an alternate: a stray
/// alias or icon set would put a Plezy icon back on the home screen.
void main() {
  final alternates = [
    for (final option in appIconCatalog)
      if (!option.isDefault) option.id,
  ];

  test('the default icon comes first and every id is unique', () {
    expect(appIconCatalog.first.id, defaultAppIconId);
    expect(appIconCatalog.map((option) => option.id).toSet(), hasLength(appIconCatalog.length));
    expect(alternates, isEmpty);
  });

  test('Android declares no alternate launcher alias, only the default .MainActivity', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final declared = RegExp(r'android:name="\.appicon\.([a-z0-9_]+)"').allMatches(manifest).map((m) => m[1]).toList();

    expect(declared, unorderedEquals(alternates));
    expect(manifest, contains('android:name=".MainActivity"'));
  });

  test('no alternate icon assets remain on Android, iOS or tvOS', () {
    final res = Directory('android/app/src/main/res');
    final androidAlternates = res
        .listSync(recursive: true)
        .map((entry) => entry.path)
        .where(
          (path) =>
              RegExp(r'(ic_launcher_[a-z]+_(background|foreground|monochrome)|tv_banner_[a-z]+)\.webp$').hasMatch(path),
        )
        .toList();
    expect(androidAlternates, isEmpty);

    for (final catalog in ['ios/Runner/AlternateAppIcons.xcassets', 'tvos/Runner/AlternateAppIcons.xcassets']) {
      final sets = Directory(catalog).listSync().where((entry) => entry.path.contains('AppIcon-')).toList();
      expect(sets, isEmpty, reason: '$catalog still holds alternate icons');
    }
  });

  test('tvOS Info.plist names no alternate icons', () {
    final plist = File('tvos/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('CFBundleAlternateIcons')));
    expect(plist, isNot(contains('AppIcon-')));
  });

  test('the default has a thumbnail for each TV launcher, which draws it on a dark plate', () {
    for (final preview in [defaultAppIconTvosPreview, defaultAppIconAndroidTvPreview]) {
      expect(File(preview).existsSync(), isTrue, reason: 'missing $preview');
    }
  });
}
