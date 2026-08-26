// FR144/N0 — the shared travel-mode list every mode picker (trip creation,
// New Route, the layer picker's "derived from" label) reads from.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/travel_mode.dart';

void main() {
  test('FR109/O4: climbing, canyoneering, and jumaring never appear as travel modes', () {
    // Punchlist fail signal §2 — these are stations, not travel modes.
    expect(kTravelModes, isNot(contains('climbing')));
    expect(kTravelModes, isNot(contains('canyoneering')));
    expect(kTravelModes, isNot(contains('jumaring')));
  });

  test('the real travel modes are exactly cycling, hiking, paddling, and transit', () {
    expect(kTravelModes.toSet(), {'cycling', 'hiking', 'paddling', 'transit'});
  });

  test('travelModeLabel gives every real mode a human label, and passes through the unknown', () {
    expect(travelModeLabel('cycling'), 'Ride');
    expect(travelModeLabel('hiking'), 'Hike');
    expect(travelModeLabel('paddling'), 'Paddle');
    expect(travelModeLabel('transit'), 'Transit');
    expect(travelModeLabel('teleportation'), 'teleportation');
  });
}
