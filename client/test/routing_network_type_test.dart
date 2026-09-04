// Issue #208 — a segment's OSMnx `network_type` follows its travel mode.
// `RoutingClient.ensureRegion` builds the graph for exactly the
// `network_type` it is handed (`region_key` is `(bbox, network_type,
// ruleset)`), so a driving passage that ensured against the default `bike`
// graph would route a car down singletrack and never see the `drive` graph's
// dropped `track`/`service` ways (SPIKE-E, #171). These tests pin that the
// client now derives and sends it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Records every `network_type` `ensureRegion` was asked for, and hands back
/// a key that encodes it so a mismatched `generateSegment` region would be
/// visible too.
class _RecordingRoutingClient extends RoutingClient {
  _RecordingRoutingClient() : super('http://fake');

  final List<String> ensuredNetworkTypes = [];

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
      {String networkType = 'bike'}) async {
    ensuredNetworkTypes.add(networkType);
    return 'region-$networkType';
  }

  @override
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async =>
      Segment(
        id: 'solved-1',
        mode: mode,
        shape: shape,
        start: start,
        end: end,
        via: via,
        geometry: LineString(
            coordinates: const [
              [-105.27, 40.02],
              [-105.26, 40.03]
            ],
            source: 'solved'),
        metrics: RouteMetrics(distanceM: targetM ?? 12000),
      );
}

({ProviderContainer container, _RecordingRoutingClient client}) _harness() {
  final client = _RecordingRoutingClient();
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(client),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(
          minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
    // Issue #246 — the settle window is 10 s in production; a test that only
    // needs to see which network_type is ensured shortens it so it does not
    // have to wait one out.
    tripRegionKeyProvider.overrideWith((ref) =>
        TripRegionKeyNotifier(ref, settleWindow: const Duration(milliseconds: 10))),
  ]);
  return (container: container, client: client);
}

void main() {
  group('networkTypeForMode mirrors multimodal/modes.py', () {
    test('the routed modes map to their registry network_type', () {
      expect(networkTypeForMode('cycling'), 'bike');
      expect(networkTypeForMode('mountain_biking'), 'bike');
      expect(networkTypeForMode('hiking'), 'walk');
      expect(networkTypeForMode('driving'), 'drive');
      expect(networkTypeForMode('paddling'), 'all');
      expect(networkTypeForMode('cross_country_skiing'), 'all');
      expect(networkTypeForMode('packrafting'), 'all');
      expect(networkTypeForMode('riverboarding'), 'all');
    });

    test('an unknown or note mode falls through to bike, as network_type_for does', () {
      expect(networkTypeForMode('transit'), 'bike');
      expect(networkTypeForMode('teleportation'), 'bike');
    });
  });

  test('tripRegionKeyProvider warms only the bike region, whatever modes are declared', () async {
    // Regression for the Buncombe County incident: this provider used to
    // `ensureRegion` for every declared mode's `network_type` at once, so a
    // trip declaring bike + hike + drive kicked off three county-scale OSMnx
    // builds in parallel the moment a bbox was accepted. The per-segment
    // solve/cue/diagnose paths still ensure their own mode's graph on demand
    // (the two tests below); this one only warms the stable `bike` anchor.
    final h = _harness();
    addTearDown(h.container.dispose);

    h.container
        .read(currentTripProvider.notifier)
        .setDeclaredModes({'cycling', 'hiking', 'driving'});

    h.container.read(tripRegionKeyProvider); // create the notifier (bbox already set)
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final state = h.container.read(tripRegionKeyProvider);
    expect(state, isA<TripRegionResolved>());
    expect((state as TripRegionResolved).key, 'region-bike');
    expect(h.client.ensuredNetworkTypes, ['bike']);
  });

  test('generateSegment ensures the region for the segment\'s mode', () async {
    final h = _harness();
    addTearDown(h.container.dispose);

    await h.container.read(currentTripProvider.notifier).generateSegment(
          start: const [-105.27, 40.02],
          end: const [-105.25, 40.04],
          shape: 'point_to_point',
          mode: 'driving',
        );

    expect(h.client.ensuredNetworkTypes, contains('drive'));
    expect(h.client.ensuredNetworkTypes, isNot(contains('bike')));
  });

  test('regenerateSegment re-solves against the segment\'s own mode graph', () async {
    final h = _harness();
    addTearDown(h.container.dispose);
    final notifier = h.container.read(currentTripProvider.notifier);

    await notifier.generateSegment(
      start: const [-105.27, 40.02],
      end: const [-105.25, 40.04],
      shape: 'point_to_point',
      mode: 'hiking',
    );
    h.client.ensuredNetworkTypes.clear();

    final day = h.container.read(currentTripProvider).days.single;
    await notifier.regenerateSegment(day.id, day.segments.single.id);

    expect(h.client.ensuredNetworkTypes, ['walk']);
  });
}
