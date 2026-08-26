// FR97 (Story N3) — per-trip layer selection, overridable per day.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/state/layer_selection_provider.dart';

void main() {
  group('LayerSelectionState.liveFor', () {
    test('a day with no override sees the trip default', () {
      const state = LayerSelectionState(tripLive: {'sight', 'historic'});
      expect(state.liveFor('day-1'), {'sight', 'historic'});
    });

    test('a day with an override sees its own set, not the trip default', () {
      const state = LayerSelectionState(
        tripLive: {'sight', 'historic'},
        dayOverrides: {'day-1': {'amenity', 'leisure'}},
      );
      expect(state.liveFor('day-1'), {'amenity', 'leisure'});
      expect(state.liveFor('day-2'), {'sight', 'historic'});
    });

    test('a null dayId always sees the trip default', () {
      const state = LayerSelectionState(
        tripLive: {'sight'},
        dayOverrides: {'day-1': {'amenity'}},
      );
      expect(state.liveFor(null), {'sight'});
    });
  });

  group('LayerSelectionNotifier', () {
    test('seedTripDefaults sets the trip-wide baseline', () {
      final notifier = LayerSelectionNotifier();
      notifier.seedTripDefaults({'sight', 'natural'});
      expect(notifier.state.tripLive, {'sight', 'natural'});
    });

    test('toggleTripLayer adds an absent layer and removes a present one', () {
      final notifier = LayerSelectionNotifier();
      notifier.seedTripDefaults({'sight'});
      notifier.toggleTripLayer('historic');
      expect(notifier.state.tripLive, {'sight', 'historic'});
      notifier.toggleTripLayer('sight');
      expect(notifier.state.tripLive, {'historic'});
    });

    test('toggleDayLayer overrides only the named day', () {
      final notifier = LayerSelectionNotifier();
      notifier.seedTripDefaults({'sight'});
      notifier.toggleDayLayer('day-1', 'amenity');
      expect(notifier.state.liveFor('day-1'), {'sight', 'amenity'});
      expect(notifier.state.liveFor('day-2'), {'sight'});
      expect(notifier.state.hasOverride('day-1'), isTrue);
      expect(notifier.state.hasOverride('day-2'), isFalse);
    });

    test('clearDayOverride drops a day back to the trip default', () {
      final notifier = LayerSelectionNotifier();
      notifier.seedTripDefaults({'sight'});
      notifier.setDayOverride('day-1', {'amenity', 'leisure'});
      expect(notifier.state.liveFor('day-1'), {'amenity', 'leisure'});
      notifier.clearDayOverride('day-1');
      expect(notifier.state.liveFor('day-1'), {'sight'});
      expect(notifier.state.hasOverride('day-1'), isFalse);
    });

    test('a riding day and a rest day can diverge (amenity excluded vs included)', () {
      // Mirrors FR97's AC directly: a sauna is excluded from a riding day's
      // sight layer and included on a rest day's amenity layer.
      final notifier = LayerSelectionNotifier();
      notifier.seedTripDefaults({'sight', 'historic', 'natural'}); // a route day's default
      notifier.setDayOverride('rest-day', {'sight', 'historic', 'natural', 'amenity', 'leisure'});
      expect(notifier.state.liveFor('route-day'), isNot(contains('amenity')));
      expect(notifier.state.liveFor('rest-day'), contains('amenity'));
    });

    group('seedForModes (FR144/N0)', () {
      test('the first call seeds the trip-wide default', () {
        final notifier = LayerSelectionNotifier();
        notifier.seedForModes({'cycling'}, {'sight', 'historic'});
        expect(notifier.state.tripLive, {'sight', 'historic'});
      });

      test('a repeat call with the same modes is a no-op — an Author\'s own edit survives', () {
        final notifier = LayerSelectionNotifier();
        notifier.seedForModes({'cycling'}, {'sight', 'historic'});
        notifier.toggleTripLayer('amenity'); // the Author's own trip-wide edit

        // Same declared modes, e.g. re-triggered by switching the active
        // day's day type — must not clobber the edit above.
        notifier.seedForModes({'cycling'}, {'sight', 'historic'});

        expect(notifier.state.tripLive, {'sight', 'historic', 'amenity'});
      });

      test('a real mode change reseeds the trip-wide default to the new defaults', () {
        final notifier = LayerSelectionNotifier();
        notifier.seedForModes({'cycling'}, {'sight', 'historic'});
        notifier.toggleTripLayer('amenity');

        notifier.seedForModes({'paddling'}, {'natural', 'leisure'});

        expect(notifier.state.tripLive, {'natural', 'leisure'});
      });

      test('a mode change leaves day-level overrides alone', () {
        final notifier = LayerSelectionNotifier();
        notifier.seedForModes({'cycling'}, {'sight', 'historic'});
        notifier.setDayOverride('rest-day', {'amenity', 'leisure'});

        notifier.seedForModes({'hiking'}, {'natural'});

        expect(notifier.state.liveFor('rest-day'), {'amenity', 'leisure'});
        expect(notifier.state.liveFor('route-day'), {'natural'});
      });

      test('mode-set order does not matter — {a,b} and {b,a} are "the same modes"', () {
        final notifier = LayerSelectionNotifier();
        notifier.seedForModes({'cycling', 'hiking'}, {'sight'});
        notifier.toggleTripLayer('amenity');

        notifier.seedForModes({'hiking', 'cycling'}, {'natural'});

        expect(notifier.state.tripLive, {'sight', 'amenity'}); // unchanged — same mode set
      });
    });
  });

  group('layerModesKey (FR144/N0)', () {
    test('is order-independent', () {
      expect(layerModesKey({'hiking', 'cycling'}), layerModesKey({'cycling', 'hiking'}));
    });

    test('falls back to cycling for an empty set (a pre-N0 trip with nothing declared)', () {
      expect(layerModesKey(const {}), layerModesKey({'cycling'}));
    });

    test('a genuinely different mode set produces a different key', () {
      expect(layerModesKey({'cycling'}) == layerModesKey({'hiking'}), isFalse);
    });
  });

  group('unionLayerCatalogs (FR144/N0)', () {
    test('unions defaultLive across every declared mode\'s catalog', () {
      final cycling = LayerCatalog(
        layers: const ['sight', 'amenity', 'natural'],
        defaultLive: const {'sight', 'natural'},
        rulesetVersion: '1.0.0',
      );
      final hiking = LayerCatalog(
        layers: const ['sight', 'amenity', 'natural'],
        defaultLive: const {'natural', 'amenity'},
        rulesetVersion: '1.0.0',
      );

      final union = unionLayerCatalogs([cycling, hiking]);

      expect(union.defaultLive, {'sight', 'natural', 'amenity'});
      expect(union.layers, cycling.layers);
      expect(union.rulesetVersion, '1.0.0');
    });

    test('a single declared mode is just that mode\'s own catalog', () {
      final catalog = LayerCatalog(
        layers: const ['sight'],
        defaultLive: const {'sight'},
        rulesetVersion: '1.0.0',
      );
      expect(unionLayerCatalogs([catalog]).defaultLive, {'sight'});
    });
  });
}
