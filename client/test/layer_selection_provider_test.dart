// FR97 (Story N3) — per-trip layer selection, overridable per day.
import 'package:flutter_test/flutter_test.dart';

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
  });
}
