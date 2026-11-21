import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/silo/silo_catalog_strings.dart';
import 'package:plezy/services/silo/silo_section_titles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => SiloCatalogStrings.debugSetTables());

  group('resolver', () {
    setUp(
      () => SiloCatalogStrings.debugSetTables(
        english: {
          'home.section.forYou': 'For You',
          'home.section.topGenre': 'Top {genre}',
          'home.section.recentlyAddedIn': 'Recently Added in {library}',
          'home.section.becauseYouWatchedTitle': 'Because You Watched {title}',
          'home.section.positional': 'Top {0} in {1}',
          'home.section.englishOnly': 'Hidden Gems',
        },
        current: {
          'home.section.forYou': 'Für dich',
          'home.section.topGenre': 'Top {genre}',
          'home.section.recentlyAddedIn': 'Kürzlich hinzugefügt in {library}',
          'home.section.becauseYouWatchedTitle': 'Weil du {titel} geschaut hast', // broken placeholder
          'home.section.positional': '{1}: Top {0}',
        },
      ),
    );

    test('a key in the current language wins, with named arguments filled', () {
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), 'Für dich');
      expect(
        SiloSectionTitles.localize(
          titleKey: 'home.section.recentlyAddedIn',
          titleArgs: {'library': 'Filme'},
          fallback: 'x',
        ),
        'Kürzlich hinzugefügt in Filme',
      );
    });

    test('positional arguments fill {0}, {1}', () {
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.positional', titleArgs: ['Drama', 'Filme'], fallback: 'x'),
        'Filme: Top Drama',
      );
    });

    test('a key the current language lacks falls back to Silo English', () {
      expect(SiloSectionTitles.localize(titleKey: 'home.section.englishOnly', fallback: 'x'), 'Hidden Gems');
    });

    test('a translation whose placeholder the arguments cannot fill falls back to English', () {
      expect(
        SiloSectionTitles.localize(
          titleKey: 'home.section.becauseYouWatchedTitle',
          titleArgs: {'title': 'Heat'},
          fallback: 'x',
        ),
        'Because You Watched Heat',
      );
    });

    test('an unknown key, a missing argument, a blank argument or no key shows the server title', () {
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.seasonal.winter.cozy', fallback: 'Cozy Winter'),
        'Cozy Winter',
      );
      expect(SiloSectionTitles.localize(titleKey: 'home.section.topGenre', fallback: 'Top X'), 'Top X');
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.topGenre', titleArgs: {'genre': '  '}, fallback: 'Top X'),
        'Top X',
      );
      expect(SiloSectionTitles.localize(titleKey: 'error.notFound', fallback: 'Mine'), 'Mine');
      expect(SiloSectionTitles.localize(titleKey: 42, fallback: 'Mine'), 'Mine');
      expect(SiloSectionTitles.of({'title': 'Picked by Laura'}), 'Picked by Laura');
    });

    test('of() reads title, title_key and title_args from a row', () {
      expect(
        SiloSectionTitles.of({
          'title': 'Top Drama',
          'title_key': 'home.section.topGenre',
          'title_args': {'genre': 'Drama'},
        }),
        'Top Drama',
      );
    });
  });

  test('with nothing loaded the server title is shown', () {
    expect(
      SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'For You (server)'),
      'For You (server)',
    );
  });

  group('bundled catalogs', () {
    test('German titles come from the bundled Silo catalog', () async {
      await SiloCatalogStrings.load(AppLocale.de);
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), 'Für dich');
      expect(
        SiloSectionTitles.localize(
          titleKey: 'home.section.becauseYouEnjoy',
          titleArgs: {'genres': 'Krimi'},
          fallback: 'x',
        ),
        'Weil du Krimi magst',
      );
    });

    test('a language Silo has no catalog for uses Silo English', () async {
      await SiloCatalogStrings.load(AppLocale.kk);
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), 'For You');
    });

    test('languages Silo added later read their own catalogs', () async {
      final expected = {
        AppLocale.bg: 'За вас',
        AppLocale.hu: 'Önnek',
        AppLocale.ja: 'おすすめ',
        AppLocale.ko: isNot('For You'),
        AppLocale.zh: '为你推荐',
        AppLocale.zhHant: '為你推薦',
      };
      for (final MapEntry(key: locale, value: matcher) in expected.entries) {
        await SiloCatalogStrings.load(locale);
        expect(
          SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'),
          matcher,
          reason: locale.languageTag,
        );
      }
      await SiloCatalogStrings.load(AppLocale.bg);
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.topGenre', titleArgs: {'genre': 'Драма'}, fallback: 'x'),
        'Най-добрите в жанра Драма',
      );
    });

    test('European Portuguese reads its own catalog, not the Brazilian one', () async {
      await SiloCatalogStrings.load(AppLocale.ptPt);
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), 'Para si');
      await SiloCatalogStrings.load(AppLocale.pt);
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), 'Para você');
    });

    test('every bundled catalog is named after a Plezilo locale tag', () {
      // scripts/silo_catalog_strings.py maps Android folders (values-iw, values-in,
      // values-b+zh+Hant, values-pt-rPT) to the tags the loader reads.
      final tags = {for (final l in AppLocale.values) l.languageTag};
      final files = Directory(SiloCatalogStrings.assetDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.endsWith('.json'))
          .map((name) => name.substring(0, name.length - '.json'.length))
          .toList();
      expect(files, contains('en'));
      expect(files.where((tag) => !tags.contains(tag)), isEmpty);
      expect(files, isNot(anyOf(contains('iw'), contains('in'))));
    });

    test('Portuguese reads the Brazilian catalog and English reads en', () async {
      await SiloCatalogStrings.load(AppLocale.pt);
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), isNot('x'));
      await SiloCatalogStrings.load(AppLocale.en);
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.topGenre', titleArgs: {'genre': 'Drama'}, fallback: 'x'),
        'Top Drama',
      );
    });
  });
}
