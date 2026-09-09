/// Legacy travel-mode aliases — issue #315. Mirrors
/// `core/plotlines_core/multimodal/legacy.py`.
///
/// `mountain_biking` / `packrafting` / `riverboarding` left the `travel_mode`
/// enum and became disciplines. A trip saved before that change carries the
/// old spelling in its `payload` blob; `Segment.fromJson` /
/// `Transition.fromJson` / the roll-up parse call [migrateLegacyMode] so it
/// loads without a schema-validation failure.
library;

/// old `travel_mode` value -> (category it became, discipline it became).
const Map<String, (String, String)> kLegacyModeAliases = {
  'mountain_biking': ('cycling', 'mountain'),
  'packrafting': ('paddling', 'packraft'),
  'riverboarding': ('paddling', 'riverboard'),
};

/// The current `travel_mode` value for a possibly-legacy one — the category a
/// removed mode folded into, or [mode] unchanged.
String canonicalMode(String mode) => kLegacyModeAliases[mode]?.$1 ?? mode;

/// The result of reading a `(mode, discipline)` pair off a stored payload,
/// with any removed mode value folded onto its category. If [mode] was a
/// removed value and no [discipline] was already stored, the discipline it
/// became is filled in — an explicit stored discipline always wins.
({String mode, String? discipline}) migrateLegacyMode(
  String mode, {
  String? discipline,
}) {
  final alias = kLegacyModeAliases[mode];
  if (alias == null) return (mode: mode, discipline: discipline);
  return (mode: alias.$1, discipline: discipline ?? alias.$2);
}
