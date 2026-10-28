import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/widgets/backend_badge.dart';

void main() {
  testWidgets('Silo shows its official icon untinted; other backends stay tinted marks', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Row(
          children: [
            BackendBadge(backend: MediaBackend.silo, size: 24, color: Colors.red),
            BackendBadge(backend: MediaBackend.jellyfin, size: 24),
          ],
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.color, isNull);
    expect(image.width, 24);
    expect((image.image as ResizeImage).imageProvider, isA<AssetImage>());
    expect(((image.image as ResizeImage).imageProvider as AssetImage).assetName, BackendBadge.siloIconAsset);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  test('the Silo icon ships with its brand notice', () {
    expect(File(BackendBadge.siloIconAsset).existsSync(), isTrue);
    expect(File('assets/brand/silo/NOTICE.txt').readAsStringSync(), contains('Silo Media L.L.C.'));
  });
}
