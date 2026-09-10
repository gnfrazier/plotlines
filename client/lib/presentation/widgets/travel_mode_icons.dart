// FR144/N0, FR10/B1 — `IconData` isn't a domain-layer concept (ARCH §10.1:
// Domain stays presentation-framework-agnostic), so this pairs with
// `domain/travel_mode.dart`'s `kTravelModes`/`travelModeLabel` rather than
// living there. Shared by `trip_mode_prompt.dart`, `new_route_screen.dart`
// and the passage inspector so a mode chip looks the same wherever it's
// offered.
//
// One glyph per travel-mode category (#315 reduced the list). Each discipline
// under a category (`discipline.dart`) carries its own glyph — issue #338, the
// per-passage discipline picker — so road / gravel / mountain don't all read as
// the same bike in the revealed row.
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

/// The glyph for a `discipline.dart` wire value (`kDisciplineKeys`) — issue
/// #338's sibling to [travelModeIcon]. The guardrail from the walkthrough is
/// that the three cycle disciplines must not all read as one bike, so each
/// discipline leans on a mark for its *surface or terrain* rather than a
/// vehicle: gravel takes a grain texture, mountain a peak, trail run a stand
/// of trees. Disciplines are distinct within their own category (a row only
/// ever shows one category at a time); a glyph reused across categories — a
/// peak for both `mountain` and `skimo` — is fine because the two never
/// appear together.
///
/// An unknown key (a plugin-declared discipline this build has never heard of)
/// falls through to a neutral "variant" mark rather than borrowing a bike.
IconData disciplineIcon(String discipline) => switch (discipline) {
      // Cycle
      'road' => Icons.directions_bike,
      'gravel' => Icons.grain,
      'mountain' => Icons.filter_hdr,
      // Foot
      'hike' => Icons.hiking,
      'run' => Icons.directions_run,
      'trail_run' => Icons.forest,
      // Paddle
      'canoe' => Icons.rowing,
      'kayak' => Icons.kayaking,
      'packraft' => Icons.backpack,
      'riverboard' => Icons.surfing,
      // Ski
      'nordic' => Icons.nordic_walking,
      'skimo' => Icons.filter_hdr,
      'backcountry' => Icons.forest,
      'resort' => Icons.downhill_skiing,
      // Drive
      'street' => Icons.directions_car,
      'high_clearance' => Icons.airport_shuttle,
      _ => Icons.tune,
    };
