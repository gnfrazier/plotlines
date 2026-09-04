// Issue #246 (OSM acquisition Phase 0, review §5.5 · addendum P3) — the
// settle window and supersede-in-flight on the accepted-bbox → `ensureRegion`
// edge.
//
// #238 measured five *completed* bbox gestures accepted in ~30 s, each one
// POSTing `/regions` immediately and each POST fanning into one Overpass query
// per sub-polygon above `max_query_area_size`. The fix waits for the accepted
// bbox to stop changing before the POST goes out, and drops any region whose
// bbox was superseded before its build could be observed. The pointer
// handlers are deliberately untouched — the map already proposes only on
// pointer-up.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Records every `ensureRegion` (i.e. every `POST /regions`) and lets a test
/// control when each one completes, so a superseded in-flight build can be
/// resolved *after* its successor and checked that its result is dropped.
class _GatedRoutingClient extends RoutingClient {
  _GatedRoutingClient({this.autoComplete = true}) : super('http://fake');

  final bool autoComplete;
  final List<List<double>> ensureCalls = [];
  final List<bool> retryFlags = [];
  final List<Completer<String>> gates = [];

  int get callCount => ensureCalls.length;

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
      {String networkType = 'bike', bool retry = false}) {
    ensureCalls.add(bboxWsen);
    retryFlags.add(retry);
    if (autoComplete) return Future.value('region-${ensureCalls.length}');
    final c = Completer<String>();
    gates.add(c);
    return c.future;
  }
}

const _boxA = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2);
const _boxB = TripBbox(minLat: 41.0, minLon: -106.3, maxLat: 41.2, maxLon: -106.0);

/// A settle window short enough that a plain `test()` can wait one out with a
/// real `Future.delayed`, standing in for production's 10 s.
const _window = Duration(milliseconds: 30);

({ProviderContainer container, TripBboxNotifier bbox, _GatedRoutingClient client})
    _harness({bool autoComplete = true}) {
  final client = _GatedRoutingClient(autoComplete: autoComplete);
  final bbox = TripBboxNotifier();
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(client),
    tripBboxProvider.overrideWith((ref) => bbox),
    tripRegionKeyProvider.overrideWith(
        (ref) => TripRegionKeyNotifier(ref, settleWindow: _window)),
  ]);
  // Instantiate the notifier so it subscribes to the bbox.
  container.read(tripRegionKeyProvider);
  return (container: container, bbox: bbox, client: client);
}

Future<void> _pump([Duration d = const Duration(milliseconds: 5)]) =>
    Future<void>.delayed(d);

void main() {
  test('a burst of accepted bboxes produces one /regions POST, for the last one', () async {
    final h = _harness();
    addTearDown(h.container.dispose);

    // Five completed gestures inside one settle window, #238's pattern
    // compressed: each keeps resetting the clock.
    for (var i = 0; i < 5; i++) {
      h.bbox.set(TripBbox(
        minLat: 40.0 + i * 0.1,
        minLon: -105.3,
        maxLat: 40.2 + i * 0.1,
        maxLon: -105.2,
      ));
      await _pump(const Duration(milliseconds: 8));
    }
    final last = h.container.read(tripBboxProvider)!;

    // Mid-burst: nothing has been POSTed yet, and the surface says why.
    expect(h.client.callCount, 0);
    expect(h.container.read(tripRegionKeyProvider), isA<TripRegionSettling>());

    await _pump(_window * 3);

    expect(h.client.callCount, 1);
    expect(h.client.ensureCalls.single, last.bboxWsen);
    final state = h.container.read(tripRegionKeyProvider);
    expect(state, isA<TripRegionResolved>());
  });

  test('a region superseded while its POST is in flight is dropped, not raced to completion',
      () async {
    final h = _harness(autoComplete: false);
    addTearDown(h.container.dispose);

    h.bbox.set(_boxA);
    await _pump(_window * 2);
    expect(h.client.callCount, 1, reason: 'A settled and its POST went out');
    expect(h.container.read(tripRegionKeyProvider), isA<TripRegionEnsuring>());

    // B is accepted while A's build is still outstanding.
    h.bbox.set(_boxB);
    await _pump(_window * 2);
    expect(h.client.callCount, 2, reason: 'B settled and its POST went out');
    expect(h.client.ensureCalls[1], _boxB.bboxWsen);

    // A's build finally finishes — its result must not surface.
    h.client.gates[0].complete('region-A');
    await _pump();
    final afterA = h.container.read(tripRegionKeyProvider);
    expect(afterA, isA<TripRegionEnsuring>());
    expect((afterA as TripRegionEnsuring).bbox, _boxB);

    // B's build finishes — that one does surface.
    h.client.gates[1].complete('region-B');
    await _pump();
    final afterB = h.container.read(tripRegionKeyProvider);
    expect(afterB, isA<TripRegionResolved>());
    expect((afterB as TripRegionResolved).key, 'region-B');
  });

  test('the settle window reports honestly on the FR121 surface — a wait, not a failure, not silence',
      () async {
    final h = _harness();
    addTearDown(h.container.dispose);

    h.bbox.set(_boxA);
    await _pump(); // still well inside the settle window

    final state = h.container.read(tripRegionKeyProvider);
    expect(state, isA<TripRegionSettling>());
    expect((state as TripRegionSettling).pending, _boxA);

    final status = routingCapabilityForRegion(state, null);
    expect(status.ready, isFalse, reason: 'the control stays disabled');
    expect(status.failed, isFalse, reason: 'a wait is not a failure');
    expect(status.reason, isNotNull);
    expect(status.reason, isNot(''), reason: 'not a silent nothing');
    expect(status.reason, contains('settle'));
    // Distinct from the no-bbox reading.
    expect(status.reason,
        isNot(routingCapabilityForRegion(const TripRegionNoBbox(), null).reason));
  });

  test('clearing the bbox during the settle window cancels the pending POST', () async {
    final h = _harness();
    addTearDown(h.container.dispose);

    h.bbox.set(_boxA);
    await _pump();
    expect(h.container.read(tripRegionKeyProvider), isA<TripRegionSettling>());

    h.bbox.reset();
    await _pump(_window * 3);

    expect(h.client.callCount, 0);
    expect(h.container.read(tripRegionKeyProvider), isA<TripRegionNoBbox>());
  });

  test('retry() re-POSTs the settled bbox immediately, skipping the settle window', () async {
    final h = _harness(autoComplete: false);
    addTearDown(h.container.dispose);

    h.bbox.set(_boxA);
    await _pump(_window * 2);
    h.client.gates[0].completeError(Exception('overpass unreachable'));
    await _pump();
    expect(h.container.read(tripRegionKeyProvider), isA<TripRegionFailed>());

    h.container.read(tripRegionKeyProvider.notifier).retry();
    await _pump(); // no settle wait

    expect(h.client.callCount, 2);
    expect(h.client.ensureCalls[1], _boxA.bboxWsen);
    expect(h.container.read(tripRegionKeyProvider), isA<TripRegionEnsuring>());

    // Issue #247 — the settle-window POST is automatic (`retry: false`); only
    // the Author's explicit "Try again" carries `retry: true`, which is what
    // earns the sidecar's one in-window cooldown bypass.
    expect(h.client.retryFlags, [false, true]);
  });

  test('the settled failure carries the error for logging but the surface phrase is fixed',
      () async {
    final h = _harness(autoComplete: false);
    addTearDown(h.container.dispose);

    h.bbox.set(_boxA);
    await _pump(_window * 2);
    h.client.gates[0].completeError(Exception('HTTPSConnectionPool(host=...)'));
    await _pump();

    final state = h.container.read(tripRegionKeyProvider);
    expect(state, isA<TripRegionFailed>());
    final status = routingCapabilityForRegion(state, null);
    expect(status.reason, 'failed:the trip area could not be prepared for routing');
  });
}
