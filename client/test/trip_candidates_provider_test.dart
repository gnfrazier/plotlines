// Issue #316 — `tripCandidatesProvider` holds the trip's extracted candidate
// set so the trip-creation layer step and the Layers tab share one warmed
// result. This pins its contract: a run reports loading → result, a failed
// run keeps the last good set and surfaces the error, `reset()` clears it,
// and a second run while one is in flight is a no-op.
//
// `CurationClient` has no HTTP-mock convention in this repo
// (`curation_client_test.dart`'s own note), so it is faked the same way
// `layers_tab_declared_modes_test.dart` fakes it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

Candidate _c(String id) => Candidate(
      id: id,
      coord: const [-105.2, 40.0],
      layer: 'sight',
      salience: 0.5,
      roleAffinity: RoleAffinity.narrative,
    );

/// Fake whose `candidatesForBbox` is scripted per test: it either returns a
/// fixed list, blocks on a completer, or throws.
class _FakeCurationClient extends CurationClient {
  _FakeCurationClient() : super('http://fake');

  int calls = 0;
  List<Candidate> result = const [];
  Object? throwThis;
  Completer<void>? gate;

  @override
  Future<List<Candidate>> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async {
    calls++;
    if (gate != null) await gate!.future;
    if (throwThis != null) throw throwThis!;
    return result;
  }
}

ProviderContainer _container(_FakeCurationClient client) {
  final c = ProviderContainer(
    overrides: [curationClientProvider.overrideWithValue(client)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('a successful run reports loading, then the candidates and its key', () async {
    final client = _FakeCurationClient()..result = [_c('a'), _c('b')];
    final container = _container(client);
    final notifier = container.read(tripCandidatesProvider.notifier);

    final future = notifier.fetch(bbox: _bbox, liveLayers: {'sight', 'natural'});
    expect(container.read(tripCandidatesProvider).loading, isTrue);

    await future;
    final state = container.read(tripCandidatesProvider);
    expect(state.loading, isFalse);
    expect(state.candidates.map((c) => c.id), ['a', 'b']);
    expect(state.error, isNull);
    expect(state.isCurrentFor(_bbox, {'sight', 'natural'}), isTrue);
    expect(state.isCurrentFor(_bbox, {'sight'}), isFalse);
  });

  test('a failed run keeps the last good set and surfaces the error', () async {
    final client = _FakeCurationClient()..result = [_c('a')];
    final container = _container(client);
    final notifier = container.read(tripCandidatesProvider.notifier);

    await notifier.fetch(bbox: _bbox, liveLayers: {'sight'});
    expect(container.read(tripCandidatesProvider).candidates.map((c) => c.id), ['a']);

    client.throwThis = StateError('sidecar down');
    await notifier.fetch(bbox: _bbox, liveLayers: {'sight', 'natural'});

    final state = container.read(tripCandidatesProvider);
    expect(state.loading, isFalse);
    expect(state.error, contains('sidecar down'));
    // Not blanked — a broken re-run must not wipe a warmed workspace.
    expect(state.candidates.map((c) => c.id), ['a']);
  });

  test('reset() clears candidates, error and the fetch key', () async {
    final client = _FakeCurationClient()..result = [_c('a')];
    final container = _container(client);
    final notifier = container.read(tripCandidatesProvider.notifier);

    await notifier.fetch(bbox: _bbox, liveLayers: {'sight'});
    notifier.reset();

    final state = container.read(tripCandidatesProvider);
    expect(state.candidates, isEmpty);
    expect(state.error, isNull);
    expect(state.fetchedFor, isNull);
  });

  test('a second fetch while one is in flight is a no-op', () async {
    final client = _FakeCurationClient()
      ..result = [_c('a')]
      ..gate = Completer<void>();
    final container = _container(client);
    final notifier = container.read(tripCandidatesProvider.notifier);

    final first = notifier.fetch(bbox: _bbox, liveLayers: {'sight'});
    await notifier.fetch(bbox: _bbox, liveLayers: {'natural'}); // returns immediately
    expect(client.calls, 1);

    client.gate!.complete();
    await first;
    expect(client.calls, 1);
    expect(container.read(tripCandidatesProvider).candidates.map((c) => c.id), ['a']);
  });
}
