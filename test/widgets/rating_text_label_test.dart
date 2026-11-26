import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_rating.dart';
import 'package:plezy/widgets/media_rating_badge.dart';

void main() {
  testWidgets("Tofa's own scores are named in words, with no mark", (tester) async {
    final ratings = [
      MediaRatingSource.fromScale('tofaCritics', 85, scale: 100)!,
      MediaRatingSource.fromScale('tofaAudience', 72, scale: 100)!,
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InlineRatingBadges(ratings: ratings)),
      ),
    );
    expect(find.text('Tofa critics 85'), findsOneWidget);
    expect(find.text('Tofa audience 72'), findsOneWidget);
    expect(mediaRatingLabel(ratings.first), '85');
    expect(ratingsSemanticLabel(ratings), 'Tofa critics 85, Tofa audience 72');
  });
}
