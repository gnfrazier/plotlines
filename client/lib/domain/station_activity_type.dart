/// FR109, FR16b, FR24 / O4 — the station-activity registry: the set of
/// activity types the app ships knowing about, each with a label and a
/// sensible default duration for the authoring control to seed.
///
/// This mirrors `core/plotlines_core/multimodal/station_activities.py`. Like
/// `discipline.dart`, the client half carries only what a picker needs — the
/// key, label and default duration — because Domain stays free of core
/// concerns (ARCH §10.1).
///
/// **Not a schema enum.** `$defs/station_activity.activity_type` is a plain
/// string: adding an activity type is a config entry in the core registry
/// (O4's AC), and a plugin may name one this build has never heard of
/// (FR144). [stationActivityLabel] falls through to the raw key for an
/// unknown activity, the same contract `disciplineLabel` has.
///
/// `station_activity_type_test.dart` pins this registry against the core key
/// list.
library;

/// One station-activity type — data a picker reads, nothing more.
class StationActivityType {
  const StationActivityType({
    required this.key,
    required this.label,
    required this.defaultDurationS,
  });

  /// The wire value carried in `role.activity.activity_type`.
  final String key;
  final String label;

  /// A sensible starting duration in seconds for this kind of stop, or `null`
  /// where there is no meaningful default. A seed for the control, never
  /// imposed — the value that feeds day timing is the one the Author sets.
  final double? defaultDurationS;
}

const double _h = 3600;

/// The set the app ships knowing about, in registry order. The first three
/// are FR109's named examples ("climbing, canyoneering, and jumaring are
/// stations, not travel modes"); the rest are the other station cases the
/// PRD reaches for.
const Map<String, StationActivityType> kStationActivityTypes = {
  'climbing': StationActivityType(
      key: 'climbing', label: 'Climbing', defaultDurationS: 3 * _h),
  'canyoneering': StationActivityType(
      key: 'canyoneering', label: 'Canyoneering', defaultDurationS: 4 * _h),
  'jumaring': StationActivityType(
      key: 'jumaring', label: 'Jumaring', defaultDurationS: 2 * _h),
  'summit_scramble': StationActivityType(
      key: 'summit_scramble', label: 'Summit scramble', defaultDurationS: 1.5 * _h),
  'hot_spring': StationActivityType(
      key: 'hot_spring', label: 'Hot spring', defaultDurationS: _h),
  'sauna': StationActivityType(
      key: 'sauna', label: 'Sauna', defaultDurationS: _h),
  'swimming': StationActivityType(
      key: 'swimming', label: 'Swimming hole', defaultDurationS: _h),
};

/// Every activity type the app ships knowing about, in registry order —
/// pinned against `station_activities.all_activity_type_keys()`.
const List<String> kStationActivityTypeKeys = [
  'climbing',
  'canyoneering',
  'jumaring',
  'summit_scramble',
  'hot_spring',
  'sauna',
  'swimming',
];

/// An activity's label, falling through to the raw key for one this build
/// does not know (a plugin-declared activity) — same contract as
/// [disciplineLabel].
String stationActivityLabel(String key) =>
    kStationActivityTypes[key]?.label ?? key;

/// An activity's seed duration, or `null` for an unknown key.
double? defaultStationActivityDurationS(String key) =>
    kStationActivityTypes[key]?.defaultDurationS;
