// FR118 (Story A0a) — compose mode's editing-decision surface: the pure
// rules behind "these seven plot points make a 94-mile day; your band was
// 55–70," presented as a report, never a conflict (A6's path, or FR140a's
// stale-list path, are both explicitly not this).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  group('statedDistanceBand', () {
    test('finds the segment\'s distance_m band', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        bands: [Band(attribute: 'distance_m', min: 88000, max: 113000)],
      );
      final band = statedDistanceBand(segment);
      expect(band?.min, 88000);
      expect(band?.max, 113000);
    });

    test('ignores bands on other attributes', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        bands: [Band(attribute: 'climb_m', min: 100, max: 2000)],
      );
      expect(statedDistanceBand(segment), isNull);
    });

    test('ignores a distance_m band with neither bound set', () {
      final segment = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        bands: [Band(attribute: 'distance_m')],
      );
      expect(statedDistanceBand(segment), isNull);
    });

    test('is null when no band is stated at all', () {
      final segment = Segment(id: 's1', mode: 'cycling', shape: 'loop');
      expect(statedDistanceBand(segment), isNull);
    });
  });

  group('distanceDeviatesFromBand', () {
    final band = Band(attribute: 'distance_m', min: 88000, max: 113000);

    test('over the max deviates', () {
      expect(distanceDeviatesFromBand(151000, band), isTrue);
    });

    test('under the min deviates', () {
      expect(distanceDeviatesFromBand(50000, band), isTrue);
    });

    test('inside the band does not deviate', () {
      expect(distanceDeviatesFromBand(100000, band), isFalse);
    });

    test('null with no realized distance yet — nothing to judge', () {
      expect(distanceDeviatesFromBand(null, band), isNull);
    });

    test('null with no stated band — nothing to judge', () {
      expect(distanceDeviatesFromBand(100000, null), isNull);
    });
  });

  group('composeDeviationHeadline', () {
    test('quotes the AC\'s pattern: place count, realized km, and the band', () {
      final band = Band(attribute: 'distance_m', min: 88000, max: 113000);
      final headline = composeDeviationHeadline(
        placeCount: 7,
        realizedDistanceM: 151000,
        band: band,
      );
      expect(
        headline,
        'These 7 plot points make a 151.0 km day. Your band was 88.0–113.0 km.',
      );
    });

    test('singular place count reads naturally', () {
      final headline = composeDeviationHeadline(placeCount: 1, realizedDistanceM: 12000);
      expect(headline, 'These 1 plot point make a 12.0 km day.');
    });

    test('omits the band sentence entirely when none is stated', () {
      final headline = composeDeviationHeadline(placeCount: 3, realizedDistanceM: 42000);
      expect(headline, 'These 3 plot points make a 42.0 km day.');
    });

    test('a one-sided band reads as "at least" / "at most"', () {
      final minOnly = composeDeviationHeadline(
        placeCount: 2,
        realizedDistanceM: 10000,
        band: Band(attribute: 'distance_m', min: 20000),
      );
      expect(minOnly, contains('at least 20.0 km'));

      final maxOnly = composeDeviationHeadline(
        placeCount: 2,
        realizedDistanceM: 10000,
        band: Band(attribute: 'distance_m', max: 5000),
      );
      expect(maxOnly, contains('at most 5.0 km'));
    });
  });

  group('widenBandToAdmit', () {
    test('raises the max to admit a realized value over it', () {
      final band = Band(attribute: 'distance_m', min: 88000, max: 113000);
      final widened = widenBandToAdmit(band, 151000);
      expect(widened.min, 88000);
      expect(widened.max, 151000);
    });

    test('lowers the min to admit a realized value under it', () {
      final band = Band(attribute: 'distance_m', min: 88000, max: 113000);
      final widened = widenBandToAdmit(band, 50000);
      expect(widened.min, 50000);
      expect(widened.max, 113000);
    });

    test('leaves a side untouched when the value already sits inside it', () {
      final band = Band(attribute: 'distance_m', min: 88000, max: 113000);
      final widened = widenBandToAdmit(band, 100000);
      expect(widened.min, 88000);
      expect(widened.max, 113000);
    });
  });

  group('composeDeviationAcceptedProvider / isDeviationAccepted', () {
    test('defaults to unaccepted for any segment id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(composeDeviationAcceptedProvider('seg-1')), isNull);
    });

    test('is scoped per segment id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(composeDeviationAcceptedProvider('seg-1').notifier).state = 151000;
      expect(container.read(composeDeviationAcceptedProvider('seg-1')), 151000);
      expect(container.read(composeDeviationAcceptedProvider('seg-2')), isNull);
    });

    test('an accepted distance still covers a re-solve that returns the same number', () {
      expect(
        isDeviationAccepted(acceptedAtDistanceM: 151000, realizedDistanceM: 151000.2),
        isTrue,
      );
    });

    test('a changed realized distance silently un-accepts', () {
      expect(
        isDeviationAccepted(acceptedAtDistanceM: 151000, realizedDistanceM: 140000),
        isFalse,
      );
    });

    test('never accepted before an explicit accept', () {
      expect(
        isDeviationAccepted(acceptedAtDistanceM: null, realizedDistanceM: 151000),
        isFalse,
      );
    });
  });
}
