import '../../i18n/strings.g.dart';

/// One home-screen icon the user can pick: the default or a Supporter alternate.
class AppIconOption {
  const AppIconOption._(this.id, this._label);

  /// Permanent platform id: the Android launcher alias `.appicon.<id>` and the
  /// Apple alternate icon `AppIcon-<id>`. Devices keep the chosen icon by this
  /// id across updates, so an id is never renamed or removed.
  final String id;

  final String Function(Translations t) _label;

  bool get isDefault => id == defaultAppIconId;

  String label(Translations t) => _label(t);

  /// The bundled picker thumbnail; null for the default, which the picker draws
  /// as this device's launcher shows it (see [defaultAppIconTvosPreview]).
  String? get previewAsset => isDefault ? null : 'assets/app_icons/previews/$id.webp';
}

/// The default icon as the TV launchers draw it, rendered from the shipping
/// tvOS image stack and Android TV banner by
/// scripts/make_plezilo_icon.py: both are gradient plates, unlike the
/// phone icons. Phone launchers draw the shipping logo on a flat plate, which
/// the picker paints itself.
const defaultAppIconTvosPreview = 'assets/app_icons/previews/default-tvos.webp';
const defaultAppIconAndroidTvPreview = 'assets/app_icons/previews/default-androidtv.webp';

/// What the platforms call the icon the app ships with.
const defaultAppIconId = 'default';

/// The picker's order, default first. Plezilo ships no alternate icons: Plezy's
/// alternates are the Plezy project's trademark (TRADEMARKS.md), so they were
/// removed with the rest of its branding. With only the default here the
/// picker stays hidden ([AppIconSetting.isShown]) and the platforms report the
/// switch as unsupported (no `.appicon.<id>` aliases, no alternate icon sets).
final List<AppIconOption> appIconCatalog = List.unmodifiable([
  AppIconOption._(defaultAppIconId, (t) => t.appIcon.defaultIcon),
]);

/// The catalog entry for a platform id; null for an id this build does not know.
AppIconOption? appIconById(String id) {
  for (final option in appIconCatalog) {
    if (option.id == id) return option;
  }
  return null;
}
