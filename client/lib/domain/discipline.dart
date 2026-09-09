/// FR10 / FR130 [#315] — the discipline: the second axis under a travel-mode
/// category (`travel_mode.dart`). Model B — a discipline is a *variant* that
/// selects a weight profile, not a category of its own. The trip declares
/// categories; a passage picks a discipline under one.
///
/// This mirrors `core/plotlines_core/multimodal/disciplines.py`. The client
/// half carries only what a picker needs — the key, label, category, tier and
/// the difficulty-grading capability flag — because Domain stays free of
/// solver concerns (ARCH §10.1); the weight profile a discipline resolves to
/// lives in core and is applied at solve time.
///
/// `grades_difficulty` is a capability flag for future B9 / FR14b work —
/// **nothing reads it yet**. SPIKE-C found OSM land grading too thin to
/// aggregate and no grading surface exists; it is here so the control does
/// not imply grading it cannot deliver.
///
/// `discipline_test.dart` pins this registry against the core key list and the
/// `$defs/discipline` schema enum.
library;

/// Discipline tiers. `firstClass` = the profile is one that shipped and was
/// measured (a category base, a SPIKE-tuned theme, or a reused ex-mode
/// profile); `extended` = the dials are a conservative first guess. A picker
/// communicates tuned-vs-generic from this, not from which row a discipline
/// sits in (issue #315).
const String kDisciplineFirstClass = 'first_class';
const String kDisciplineExtended = 'extended';

/// One discipline — data a picker reads, nothing more.
class Discipline {
  const Discipline({
    required this.key,
    required this.label,
    required this.category,
    required this.tier,
    required this.gradesDifficulty,
  });

  /// The wire value carried in `segment.discipline`.
  final String key;
  final String label;

  /// A `kTravelCategories` value — the mode this discipline refines.
  final String category;

  /// [kDisciplineFirstClass] or [kDisciplineExtended].
  final String tier;

  /// Future B9 / FR14b capability flag. Not consumed anywhere yet.
  final bool gradesDifficulty;

  bool get isFirstClass => tier == kDisciplineFirstClass;
}

/// The MVP discipline set, in category order — the owner's #315 comment.
/// `riverboard` is carried for wire validity and the legacy migration
/// (`packrafting`'s sibling was `riverboarding`) but is not offered at MVP.
const Map<String, Discipline> kDisciplines = {
  // Cycle
  'road': Discipline(
      key: 'road', label: 'Road', category: 'cycling',
      tier: kDisciplineFirstClass, gradesDifficulty: true),
  'gravel': Discipline(
      key: 'gravel', label: 'Gravel', category: 'cycling',
      tier: kDisciplineFirstClass, gradesDifficulty: true),
  'mountain': Discipline(
      key: 'mountain', label: 'Mountain', category: 'cycling',
      tier: kDisciplineFirstClass, gradesDifficulty: true),
  // Foot
  'hike': Discipline(
      key: 'hike', label: 'Hike', category: 'hiking',
      tier: kDisciplineFirstClass, gradesDifficulty: true),
  'run': Discipline(
      key: 'run', label: 'Run', category: 'hiking',
      tier: kDisciplineExtended, gradesDifficulty: true),
  'trail_run': Discipline(
      key: 'trail_run', label: 'Trail run', category: 'hiking',
      tier: kDisciplineExtended, gradesDifficulty: true),
  // Paddle
  'canoe': Discipline(
      key: 'canoe', label: 'Canoe', category: 'paddling',
      tier: kDisciplineFirstClass, gradesDifficulty: false),
  'kayak': Discipline(
      key: 'kayak', label: 'Kayak', category: 'paddling',
      tier: kDisciplineFirstClass, gradesDifficulty: false),
  'packraft': Discipline(
      key: 'packraft', label: 'Packraft', category: 'paddling',
      tier: kDisciplineFirstClass, gradesDifficulty: false),
  'riverboard': Discipline(
      key: 'riverboard', label: 'Riverboard', category: 'paddling',
      tier: kDisciplineExtended, gradesDifficulty: false),
  // Ski
  'nordic': Discipline(
      key: 'nordic', label: 'Nordic', category: 'cross_country_skiing',
      tier: kDisciplineExtended, gradesDifficulty: false),
  'skimo': Discipline(
      key: 'skimo', label: 'Skimo', category: 'cross_country_skiing',
      tier: kDisciplineExtended, gradesDifficulty: false),
  'backcountry': Discipline(
      key: 'backcountry', label: 'Backcountry', category: 'cross_country_skiing',
      tier: kDisciplineExtended, gradesDifficulty: false),
  'resort': Discipline(
      key: 'resort', label: 'Resort', category: 'cross_country_skiing',
      tier: kDisciplineExtended, gradesDifficulty: false),
  // Drive
  'street': Discipline(
      key: 'street', label: 'Street', category: 'driving',
      tier: kDisciplineExtended, gradesDifficulty: false),
  'high_clearance': Discipline(
      key: 'high_clearance', label: 'High clearance', category: 'driving',
      tier: kDisciplineExtended, gradesDifficulty: false),
};

/// Every `$defs/discipline` value, in registry order.
const List<String> kDisciplineKeys = [
  'road', 'gravel', 'mountain',
  'hike', 'run', 'trail_run',
  'canoe', 'kayak', 'packraft', 'riverboard',
  'nordic', 'skimo', 'backcountry', 'resort',
  'street', 'high_clearance',
];

/// The discipline keys that refine [category], in registry order.
List<String> disciplinesForCategory(String category) => [
      for (final e in kDisciplines.entries)
        if (e.value.category == category) e.key,
    ];

/// The category a discipline refines, or `null` for an unknown key.
String? categoryOfDiscipline(String key) => kDisciplines[key]?.category;

/// A discipline's label, falling through to the raw key for one this build
/// does not know (a plugin-declared discipline).
String disciplineLabel(String key) => kDisciplines[key]?.label ?? key;
