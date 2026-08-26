/// FR10/B1, FR144/N0 — the real, offerable travel modes, shared by the
/// trip-creation mode-declaration prompt (`trip_mode_prompt.dart`), New
/// Route's per-segment mode picker, the passage inspector's mode picker, and
/// the layer picker's "defaults derived from" label, so all of them always
/// agree on the same list and labels.
///
/// This mirrors `core/plotlines_core/multimodal/modes.py`'s registry, which is
/// where a mode's weight profile and domain parameters live (FR130: adding a
/// traversal mode is a `WeightProfile` entry plus domain parameters, never a
/// parallel scorer). The client half carries only what a picker needs — the
/// list, the tier, and the label — because Domain stays free of solver
/// concerns (ARCH §10.1).
///
/// **FR109/O4 guard:** climbing, canyoneering, and jumaring are stations, not
/// travel modes, and must never appear here — see
/// `travel_mode_test.dart`'s regression check.
library;

/// FR10's traversal modes, in the order the PRD states them: cycling, hiking,
/// paddling, cross-country skiing, packrafting, riverboarding, mountain
/// biking, and driving. Driving is a **routed** mode (FR29 [AMENDED v2.0]),
/// not a note — the last mile to the trailhead is often the day's worst.
///
/// Canonical order — used wherever a single "primary" mode has to be picked
/// out of a set deterministically (e.g. New Route's default per-segment
/// mode), rather than relying on a `Set`'s insertion order.
const List<String> kTraversalModes = [
  'cycling',
  'hiking',
  'paddling',
  'cross_country_skiing',
  'packrafting',
  'riverboarding',
  'mountain_biking',
  'driving',
];

/// The three PRD §10 names as first-class at MVP. The rest are authorable
/// today and absorbed by `WeightProfile` config; what "first-class" buys is a
/// tuned profile and a router that has been measured against real routes, not
/// the mode's existence.
const List<String> kFirstClassTravelModes = ['cycling', 'hiking', 'paddling'];

/// FR29's other half — train, shuttle and flight legs are **authored notes**
/// carrying carrier, identifiers and scheduled times, never solved. A payload
/// mode value that is deliberately not a traversal mode.
const List<String> kTransportNoteModes = ['transit'];

/// Every value `$defs/travel_mode` accepts. Traversal modes first, then the
/// note modes, matching `multimodal.modes.all_mode_keys()`.
const List<String> kTravelModes = [...kTraversalModes, ...kTransportNoteModes];

/// True for a mode that produces a solved route with metrics and a cue sheet.
/// False for `transit`, whose timing is an authored schedule.
bool isRoutedMode(String mode) => kTraversalModes.contains(mode);

/// True for one of the three MVP-tuned modes.
bool isFirstClassMode(String mode) => kFirstClassTravelModes.contains(mode);

String travelModeLabel(String mode) => switch (mode) {
      'cycling' => 'Ride',
      'paddling' => 'Paddle',
      'hiking' => 'Hike',
      'cross_country_skiing' => 'Ski',
      'packrafting' => 'Packraft',
      'riverboarding' => 'Riverboard',
      'mountain_biking' => 'MTB',
      'driving' => 'Drive',
      'transit' => 'Transit',
      _ => mode,
    };
