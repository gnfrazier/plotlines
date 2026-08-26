// FR144/N0 — `IconData` isn't a domain-layer concept (ARCH §10.1: Domain
// stays presentation-framework-agnostic), so this pairs with
// `domain/travel_mode.dart`'s `kTravelModes`/`travelModeLabel` rather than
// living there. Shared by `trip_mode_prompt.dart` and `new_route_screen.dart`
// so a mode chip looks the same wherever it's offered.
library;

import 'package:flutter/material.dart';

IconData travelModeIcon(String mode) => switch (mode) {
      'hiking' => Icons.hiking,
      'paddling' => Icons.kayaking,
      'transit' => Icons.directions_transit,
      _ => Icons.directions_bike,
    };
