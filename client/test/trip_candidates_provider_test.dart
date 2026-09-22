// Issue #316 — `tripCandidatesProvider` holds the trip's extracted candidate
// set so the trip-creation layer step and the Layers tab share one warmed
// result. This pins its contract: a run reports loading → result, a failed
// run keeps the last good set and surfaces the error, `reset()` clears it,
// and a second run while one is in flight is a no-op.
//
// `CurationClient` has no HTTP-mock convention in this repo
// (`curation_client_test.dart`'s own note), so it is faked the same way
// `layers_tab_modes_test.dart` fakes it.
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

Candidate _c(String id, {String layer = 'sight'}) => Candidate(
      id: id,
      coord: const [-105.2, 40.0],
      layer: layer,
      salience: 0.5,
      roleAffinity: RoleAffinity.narrative,
    );

/// Fake whose `candidatesForBbox` is scripted per test: it either returns a
/// fixed list, blocks on a completer, or throws. [extraction], when set,
/// wins over [result] so a test can script the served/unavailable lists.
class _FakeCurationClient extends CurationClient {
  _FakeCurationClient() : super('http://fake');

  int calls = 0;
  List<Set<String>> requestedLayers = [];
  List<Candidate> result = const [];
  CandidateExtraction? extraction;
  Object? throwThis;
  Completer<void>? gate;

  @override
  Future<CandidateExtraction> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async {
    calls++;
    requestedLayers.add(liveLayers);
    if (gate != null) await gate!.future;
    if (throwThis != null) throw throwThis!;
    return extraction ?? CandidateExtraction(candidates: result, layersServed: liveLayers.toList());
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

  // Issue #496 — a timed-out `/candidates` call now raises a
  // `CurationException` with an honest sentence (never a bare
  // `TimeoutException`); this pins that the state's `error` — which
  // `layers_tab.dart`'s `_ErrorBanner` renders verbatim — carries that
  // sentence and not `CurationException`'s `toString()` (the class name
  // and status code prefix M13 exists to keep off the screen).
  test('a CurationException surfaces its honest message, not its toString()', () async {
    final client = _FakeCurationClient()
      ..throwThis = CurationException(
          503, '{"detail": "the sidecar didn\'t answer while extracting candidates for this area — try again in a moment"}');
    final container = _container(client);
    final notifier = container.read(tripCandidatesProvider.notifier);

    await notifier.fetch(bbox: _bbox, liveLayers: {'sight'});

    final state = container.read(tripCandidatesProvider);
    expect(state.error, "the sidecar didn't answer while extracting candidates for this area — try again in a moment");
    expect(state.error, isNot(contains('CurationException')));
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

  group('#415 — a partially served run', () {
    test('keeps the served candidates and records which layers did not arrive', () async {
      final client = _FakeCurationClient()
        ..extraction = CandidateExtraction(
          candidates: [_c('a')],
          layersServed: const ['sight'],
          layersUnavailable: const {'plugin_crags': 'failed:TimeoutError'},
        );
      final container = _container(client);
      await container
          .read(tripCandidatesProvider.notifier)
          .fetch(bbox: _bbox, liveLayers: {'sight', 'plugin_crags'});

      final state = container.read(tripCandidatesProvider);
      expect(state.candidates.map((c) => c.id), ['a']);
      expect(state.error, isNull, reason: 'a 200 with a missing layer is not an exception');
      expect(state.layersServed, ['sight']);
      expect(state.layersUnavailable, {'plugin_crags': 'failed:TimeoutError'});
      expect(state.isPartiallyServed, isTrue);
      expect(state.isTotalFailure, isFalse);
    });

    test('nothing served is the total case', () async {
      final client = _FakeCurationClient()
        ..extraction = const CandidateExtraction(
          candidates: [],
          layersServed: [],
          layersUnavailable: {'sight': 'failed:ConnectionError'},
        );
      final container = _container(client);
      await container.read(tripCandidatesProvider.notifier).fetch(bbox: _bbox, liveLayers: {'sight'});

      final state = container.read(tripCandidatesProvider);
      expect(state.isPartiallyServed, isFalse);
      expect(state.isTotalFailure, isTrue);
    });

    test('retryUnavailable re-requests only the missing layers and merges the result', () async {
      final client = _FakeCurationClient()
        ..extraction = CandidateExtraction(
          candidates: [_c('a')],
          layersServed: const ['sight'],
          layersUnavailable: const {'plugin_crags': 'failed:TimeoutError', 'historic': 'loading'},
        );
      final container = _container(client);
      final notifier = container.read(tripCandidatesProvider.notifier);
      await notifier.fetch(bbox: _bbox, liveLayers: {'sight', 'plugin_crags', 'historic'});

      // The retry serves historic and still cannot serve the plugin layer.
      client.extraction = CandidateExtraction(
        candidates: [_c('h1', layer: 'historic')],
        layersServed: const ['historic'],
        layersUnavailable: const {'plugin_crags': 'failed:TimeoutError'},
      );
      await notifier.retryUnavailable();

      expect(client.calls, 2);
      expect(client.requestedLayers.last, {'plugin_crags', 'historic'},
          reason: 'the served layer is not re-fetched — its candidates are already on the map');
      final state = container.read(tripCandidatesProvider);
      expect(state.candidates.map((c) => c.id), ['a', 'h1']);
      expect(state.layersServed, ['sight', 'historic']);
      expect(state.layersUnavailable, {'plugin_crags': 'failed:TimeoutError'});
      expect(state.isPartiallyServed, isTrue);
      // The fetch key still describes the whole live set the workspace asked for.
      expect(state.isCurrentFor(_bbox, {'sight', 'plugin_crags', 'historic'}), isTrue);
    });

    test('a retry that serves everything clears the partial state', () async {
      final client = _FakeCurationClient()
        ..extraction = CandidateExtraction(
          candidates: [_c('a')],
          layersServed: const ['sight'],
          layersUnavailable: const {'historic': 'loading'},
        );
      final container = _container(client);
      final notifier = container.read(tripCandidatesProvider.notifier);
      await notifier.fetch(bbox: _bbox, liveLayers: {'sight', 'historic'});

      client.extraction = CandidateExtraction(
        candidates: [_c('h1', layer: 'historic')],
        layersServed: const ['historic'],
      );
      await notifier.retryUnavailable();

      final state = container.read(tripCandidatesProvider);
      expect(state.layersUnavailable, isEmpty);
      expect(state.isPartiallyServed, isFalse);
      expect(state.candidates.map((c) => c.id), ['a', 'h1']);
    });

    test('retryUnavailable is a no-op with nothing unavailable, and keeps the set on failure', () async {
      final client = _FakeCurationClient()..result = [_c('a')];
      final container = _container(client);
      final notifier = container.read(tripCandidatesProvider.notifier);
      await notifier.fetch(bbox: _bbox, liveLayers: {'sight'});
      await notifier.retryUnavailable();
      expect(client.calls, 1);

      client.extraction = CandidateExtraction(
          candidates: [_c('a')],
          layersServed: const ['sight'],
          layersUnavailable: const {'historic': 'loading'},
        );
      await notifier.fetch(bbox: _bbox, liveLayers: {'sight', 'historic'});
      client.throwThis = StateError('sidecar down');
      await notifier.retryUnavailable();

      final state = container.read(tripCandidatesProvider);
      expect(state.candidates.map((c) => c.id), ['a']);
      expect(state.layersUnavailable, {'historic': 'loading'});
      expect(state.error, contains('sidecar down'));
    });
  });
}
