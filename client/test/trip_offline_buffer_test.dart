// Story C14 (issue #51), FR35 — "Authors set the offline data buffer
// distance (corridor around the finished route) saved as a download
// parameter for the adventure package." Covers `Trip.offlineBufferM`'s
// round trip and the `CurrentTripNotifier` mutator; the Logistics tab's
// mi/km input is covered separately in `logistics_tab_offline_buffer_test.dart`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Trip _trip({double? offlineBufferM}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      offlineBufferM: offlineBufferM,
    );

void main() {
  group('Trip.offlineBufferM JSON round trip', () {
    test('a set value survives fromJson/toJson', () {
      final json = _trip(offlineBufferM: 8000.0).toJson();
      expect(json['offline_buffer_m'], 8000.0);

      final read = Trip.fromJson(json);
      expect(read.offlineBufferM, 8000.0);
    });

    test('an unset value is absent from toJson, not null', () {
      final json = _trip().toJson();
      expect(json.containsKey('offline_buffer_m'), isFalse);
    });

    test('a deliberate zero is distinguishable from unset', () {
      final json = _trip(offlineBufferM: 0.0).toJson();
      expect(json['offline_buffer_m'], 0.0);

      final read = Trip.fromJson(json);
      expect(read.offlineBufferM, 0.0);
    });

    test('fromJson accepts an integer where a fractional value was meant', () {
      // Schema rule 5 — a writer may emit `8000` where `8000.0` was meant.
      final read = Trip.fromJson({..._trip().toJson(), 'offline_buffer_m': 8000});
      expect(read.offlineBufferM, 8000.0);
    });
  });

  group('Trip.copyWith', () {
    test('offlineBufferM sets the value', () {
      final trip = _trip().copyWith(offlineBufferM: 5000.0);
      expect(trip.offlineBufferM, 5000.0);
    });

    test('clearOfflineBufferM clears it — a bare null leaves it unchanged', () {
      final withBuffer = _trip(offlineBufferM: 5000.0);
      expect(withBuffer.copyWith().offlineBufferM, 5000.0); // unchanged
      expect(withBuffer.copyWith(clearOfflineBufferM: true).offlineBufferM, isNull);
    });
  });

  group('CurrentTripNotifier.setOfflineBufferM', () {
    test('sets the trip-level buffer distance', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip());

      container.read(currentTripProvider.notifier).setOfflineBufferM(8000.0);
      expect(container.read(currentTripProvider).offlineBufferM, 8000.0);
    });

    test('setting a deliberate zero is not the same as clearing', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip());

      container.read(currentTripProvider.notifier).setOfflineBufferM(0.0);
      expect(container.read(currentTripProvider).offlineBufferM, 0.0);
    });

    test('passing null clears it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(offlineBufferM: 8000.0));

      container.read(currentTripProvider.notifier).setOfflineBufferM(null);
      expect(container.read(currentTripProvider).offlineBufferM, isNull);
    });
  });
}
