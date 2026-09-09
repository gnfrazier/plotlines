// FR144/N0, FR10/B1 — `IconData` isn't a domain-layer concept (ARCH §10.1:
// Domain stays presentation-framework-agnostic), so this pairs with
// `domain/travel_mode.dart`'s `kTravelModes`/`travelModeLabel` rather than
// living there. Shared by `trip_mode_prompt.dart`, `new_route_screen.dart`
// and the passage inspector so a mode chip looks the same wherever it's
// offered.
//
// One glyph per travel-mode category (#315 reduced the list). A discipline
// under a category (`discipline.dart`) has no glyph of its own at MVP — the
// per-passage discipline picker is a fast-follow; when it lands, each
// discipline within a category needs a distinct glyph so road / gravel /
// mountain don't all read as the same bike.
library;

import 'package:flutter/material.dart';

IconData travelModeIcon(String mode) => switch (mode) {
      'hiking' => Icons.hiking,
      'paddling' => Icons.kayaking,
      'cross_country_skiing' => Icons.downhill_skiing,
      'driving' => Icons.directions_car,
      'transit' => Icons.directions_transit,
      _ => Icons.directions_bike,
    };
