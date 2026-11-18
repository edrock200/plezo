import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';

/// Silo's own translations of the row titles its server words itself
/// (`home.section.*`), bundled in `assets/silo_i18n/<locale>.json` by
/// `scripts/silo_catalog_strings.py` from Silo's AGPL-3.0 catalogs (notice:
/// `assets/silo_i18n/NOTICE.txt`, on the licenses page).
///
/// Lookups are synchronous: [load] reads English and the app's language once
/// at start and again whenever the language changes. Until then (and in a
/// locale Silo has no catalog for) [lookup] answers from English, or null.
abstract final class SiloCatalogStrings {
  static const assetDir = 'assets/silo_i18n';

  static Map<String, String> _english = const {};
  static Map<String, String> _current = const {};
  static AppLocale? _currentLocale;

  /// Reads the English catalog (once) and [locale]'s, if Silo has one.
  /// Never throws: a missing or unreadable file leaves that table empty.
  static Future<void> load(AppLocale locale, {AssetBundle? bundle}) async {
    final source = bundle ?? rootBundle;
    if (_english.isEmpty) _english = await _read(source, AppLocale.en);
    if (locale == AppLocale.en) {
      _current = _english;
    } else if (locale != _currentLocale || _current.isEmpty) {
      _current = await _read(source, locale);
      // A regional variant without its own catalog (pt-PT) reads its base
      // language's (pt) before falling back to English.
      if (_current.isEmpty && locale.languageTag.contains('-')) {
        final base = AppLocale.values.where((l) => l.languageTag == locale.languageCode).firstOrNull;
        if (base != null && base != AppLocale.en) _current = await _read(source, base);
      }
    }
    _currentLocale = locale;
  }

  static Future<Map<String, String>> _read(AssetBundle bundle, AppLocale locale) async {
    try {
      final raw = await bundle.loadString('$assetDir/${locale.languageTag}.json', cache: false);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (value is String && value.isNotEmpty) key.toString(): value,
      };
    } catch (_) {
      // No catalog for this language (most likely) or a broken asset.
      if (locale == AppLocale.en) appLogger.w('Silo catalog strings: English catalog missing');
      return const {};
    }
  }

  /// The catalog text for [key] in the loaded language, or null.
  static String? current(String key) => _current[key];

  /// The English catalog text for [key], or null.
  static String? english(String key) => _english[key];

  static final _placeholder = RegExp(r'\{([^{}]+)\}');

  /// [key]'s text in the loaded language, else Silo's English, with every
  /// `{name}` filled from [args]; null when neither catalog has a text whose
  /// placeholders [args] can all fill.
  static String? format(String key, Map<String, String> args) => fill(current(key), args) ?? fill(english(key), args);

  /// [template] with every `{name}` replaced from [args], or null when there
  /// is no template or it needs an argument [args] lacks.
  static String? fill(String? template, Map<String, String> args) {
    if (template == null || template.isEmpty) return null;
    var missing = false;
    final filled = template.replaceAllMapped(_placeholder, (m) {
      final value = args[m.group(1)!.trim()];
      if (value == null) missing = true;
      return value ?? '';
    });
    return missing ? null : filled;
  }

  @visibleForTesting
  static void debugSetTables({Map<String, String> english = const {}, Map<String, String> current = const {}}) {
    _english = english;
    _current = current;
    _currentLocale = null;
  }
}
