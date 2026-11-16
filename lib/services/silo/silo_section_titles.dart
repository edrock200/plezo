import 'silo_catalog_strings.dart';

/// Row titles the Silo server words itself (Home and library sections,
/// recommendation rows) carry `title_key` and, when the message has
/// placeholders, `title_args`: a key of Silo's shared translation catalog
/// (`home.section.*`) whose English is the row's `title`. A client that knows
/// the key shows its own translation; otherwise, and whenever the fields are
/// absent (an administrator or the profile typed the title), it shows `title`
/// (silo-server `docs/catalog-api.md`, "Section titles").
///
/// The translations are Silo's own catalog text ([SiloCatalogStrings]); the
/// order is the app's language, then Silo's English, then the server's title.
abstract final class SiloSectionTitles {
  static const _prefix = 'home.section.';
  static final _placeholder = RegExp(r'\{([^{}]+)\}');

  /// The title to show for a row whose JSON is [row] (`title`, `title_key`,
  /// `title_args`).
  static String of(Map<String, dynamic> row) =>
      localize(titleKey: row['title_key'], titleArgs: row['title_args'], fallback: row['title']?.toString() ?? '');

  /// [titleKey] in the app's language with [titleArgs] filled in, or
  /// [fallback] when the key is unknown or a placeholder it needs is missing.
  ///
  /// [titleArgs] is a map of named arguments (`{"genre": "Drama"}` fills
  /// `{genre}`) or a list of positional ones (`["Drama"]` fills `{0}`).
  static String localize({required Object? titleKey, Object? titleArgs, required String fallback}) {
    if (titleKey is! String || !titleKey.startsWith(_prefix)) return fallback;
    final args = <String, String>{
      if (titleArgs is Map)
        for (final MapEntry(:key, :value) in titleArgs.entries) key.toString(): ?_arg(value),
      if (titleArgs is List)
        for (final (index, value) in titleArgs.indexed) '$index': ?_arg(value),
    };
    return _fill(SiloCatalogStrings.current(titleKey), args) ??
        _fill(SiloCatalogStrings.english(titleKey), args) ??
        fallback;
  }

  static String? _arg(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// [template] with every `{name}` replaced from [args], or null when there
  /// is no template or it needs an argument [args] lacks.
  static String? _fill(String? template, Map<String, String> args) {
    if (template == null || template.isEmpty) return null;
    var missing = false;
    final filled = template.replaceAllMapped(_placeholder, (m) {
      final value = args[m.group(1)!.trim()];
      if (value == null) missing = true;
      return value ?? '';
    });
    return missing ? null : filled;
  }
}
