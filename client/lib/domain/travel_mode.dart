/// FR144/N0 — the real, offerable travel modes, shared by the trip-creation
/// mode-declaration prompt (`trip_mode_prompt.dart`), New Route's per-segment
/// mode picker, and the layer picker's "defaults derived from" label, so all
/// three always agree on the same list and labels.
///
/// **FR109/O4 guard:** climbing, canyoneering, and jumaring are stations, not
/// travel modes, and must never appear here — see
/// `travel_mode_test.dart`'s regression check.
library;

/// Canonical order — used wherever a single "primary" mode has to be picked
/// out of a set deterministically (e.g. New Route's default per-segment
/// mode), rather than relying on a `Set`'s insertion order.
const List<String> kTravelModes = ['cycling', 'hiking', 'paddling', 'transit'];

String travelModeLabel(String mode) => switch (mode) {
      'cycling' => 'Ride',
      'paddling' => 'Paddle',
      'hiking' => 'Hike',
      'transit' => 'Transit',
      _ => mode,
    };
