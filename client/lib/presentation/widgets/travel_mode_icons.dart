// FR144/N0, FR10/B1 — `IconData` isn't a domain-layer concept (ARCH §10.1:
// Domain stays presentation-framework-agnostic), so this pairs with
// `domain/travel_mode.dart`'s `kTravelModes`/`travelModeLabel` rather than
// living there. Shared by `trip_mode_prompt.dart`, `new_route_screen.dart`
// and the passage inspector so a mode chip looks the same wherever it's
// offered.
//
// Every FR10 traversal mode gets a distinct glyph: a mode picker that shows
// the same bike for cycling and mountain biking makes the two unreadable at a
// glance, which is the whole job of the icon.
library;

import 'package:flutter/material.dart';

IconData travelModeIcon(String mode) => switch (mode) {
      'hiking' => Icons.hiking,
      'paddling' => Icons.kayaking,
      'cross_country_skiing' => Icons.downhill_skiing,
      'packrafting' => Icons.rowing,
      'riverboarding' => Icons.surfing,
      'mountain_biking' => Icons.pedal_bike,
      'driving' => Icons.directions_car,
      'transit' => Icons.directions_transit,
      _ => Icons.directions_bike,
    };
