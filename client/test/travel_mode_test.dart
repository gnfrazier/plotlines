// FR10/B1, FR144/N0 — the shared travel-mode list every mode picker (trip
// creation, New Route, the passage inspector, the layer picker's "derived
// from" label) reads from, and the client half of
// `core/plotlines_core/multimodal/modes.py`'s registry.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/message_catalog.dart';
import 'package:plotlines_client/domain/travel_mode.dart';

void main() {
  test('FR109/O4: climbing, canyoneering, and jumaring never appear as travel modes', () {
    // Punchlist fail signal §2.6 — these are stations, not travel modes.
    for (final activity in ['climbing', 'canyoneering', 'jumaring']) {
      expect(kTravelModes, isNot(contains(activity)));
      expect(kTraversalModes, isNot(contains(activity)));
      expect(kFirstClassTravelModes, isNot(contains(activity)));
    }
  });

  test('the traversal list is FR10\'s eight modes, in the order the PRD states them', () {
    expect(kTraversalModes, [
      'cycling',
      'hiking',
      'paddling',
      'cross_country_skiing',
      'packrafting',
      'riverboarding',
      'mountain_biking',
      'driving',
    ]);
  });

  test('driving is a traversal mode, not a note', () {
    // Punchlist fail signal §2.11 — "driving is absent from the traversal-mode
    // list; or a drive to the trailhead produces a note rather than a route."
    expect(kTraversalModes, contains('driving'));
    expect(kTransportNoteModes, isNot(contains('driving')));
    expect(isRoutedMode('driving'), isTrue);
  });

  test('transit is FR29\'s authored-note leg and never a traversal mode', () {
    expect(kTransportNoteModes, ['transit']);
    expect(kTraversalModes, isNot(contains('transit')));
    expect(isRoutedMode('transit'), isFalse);
    // Still an offerable mode value — a trip declares it (FR144) and the
    // payload accepts it; it is just never solved.
    expect(kTravelModes, contains('transit'));
  });

  test('cycling, hiking and paddling are the first-class modes at MVP', () {
    expect(kFirstClassTravelModes, ['cycling', 'hiking', 'paddling']);
    for (final mode in kFirstClassTravelModes) {
      expect(isFirstClassMode(mode), isTrue, reason: mode);
      expect(kTraversalModes, contains(mode), reason: mode);
    }
    for (final mode in ['cross_country_skiing', 'packrafting', 'riverboarding',
      'mountain_biking', 'driving']) {
      expect(isFirstClassMode(mode), isFalse, reason: mode);
    }
  });

  test('kTravelModes is the traversal list followed by the note modes', () {
    expect(kTravelModes, [...kTraversalModes, ...kTransportNoteModes]);
  });

  test('travelModeLabel gives every real mode a human label, and passes through the unknown', () {
    for (final mode in kTravelModes) {
      expect(travelModeLabel(mode), isNot(mode), reason: mode);
      expect(travelModeLabel(mode), isNotEmpty, reason: mode);
    }
    expect(travelModeLabel('cycling'), 'Ride');
    expect(travelModeLabel('driving'), 'Drive');
    expect(travelModeLabel('mountain_biking'), 'MTB');
    expect(travelModeLabel('teleportation'), 'teleportation');
  });

  test('FR145/M14: every mode has a localizable term, and the two labels agree', () {
    const resolver = MessageResolver();
    for (final mode in kTravelModes) {
      final id = resolver.travelModeTerm(mode);
      expect(id, isNotNull, reason: 'no message term for mode "$mode"');
      // The `en` term and the plain label are the same string — a picker and a
      // sentence must not disagree about what the mode is called.
      expect(resolver.resolve(id!), travelModeLabel(mode), reason: mode);
    }
    expect(resolver.travelModeTerm('teleportation'), isNull);
  });

  test('the payload schema enum is exactly kTravelModes', () {
    // The Dart list, the Python registry and the schema are three mirrors of
    // one decision; this is the client-side half of that pin
    // (`core/tests/test_modes.py` holds the Python half).
    final schema = jsonDecode(
      File('../docs/schemas/trip_payload.schema.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final defs = schema[r'$defs'] as Map<String, dynamic>;
    final enumValues = (defs['travel_mode'] as Map<String, dynamic>)['enum'] as List;
    expect(enumValues.cast<String>(), kTravelModes);
  });
}
