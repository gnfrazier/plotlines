// Story H6 (issue #80) — the Character-side personalization provider.
//
// Covers `state/character_variant_provider.dart`: the variant is per-passage,
// starts empty (canonical route), and the mutation helpers move it only
// within the Author's bounds. The provider holds a layer — nothing here
// touches a `Trip`/`Segment`, so canon cannot be reached from this surface.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/character_variant_provider.dart';

void main() {
  Segment authoredSegment() => Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'loop',
        start: const [-105.27, 40.02],
        bands: [Band(attribute: 'climb_m', min: 200.0, max: 600.0, source: 'author')],
        metrics: RouteMetrics(distanceM: 25000.0, climbM: 450.0),
        alternates: [
          Alternate(
            id: 'alt-bypass',
            kind: 'bypass',
            geometry: LineString(coordinates: const [
              [-105.27, 40.02],
              [-105.25, 40.03],
            ]),
            metrics: RouteMetrics(distanceM: 21000.0, climbM: 180.0),
          ),
        ],
      );

  // A minimal WidgetRef stand-in backed by a real ProviderContainer — enough
  // for the `ref.read(provider.notifier)` calls the helpers make.
  ({ProviderContainer container, WidgetRef ref}) harness() {
    final container = ProviderContainer();
    return (container: container, ref: _ContainerRef(container));
  }

  test('a fresh passage starts on the canonical route (empty variant)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final v = container.read(characterVariantProvider('seg-1'));
    expect(v.segmentId, 'seg-1');
    expect(v.isEmpty, isTrue);
  });

  test('adjustCharacterParameter clamps into the Author band and stores the target', () {
    final h = harness();
    addTearDown(h.container.dispose);
    final s = authoredSegment();

    adjustCharacterParameter(h.ref, s, 'climb_m', 5000.0);

    expect(h.container.read(characterVariantProvider(s.id)).bandTargets['climb_m'], 600.0);
  });

  test('adjustCharacterParameter on a locked attribute throws and stores nothing', () {
    final h = harness();
    addTearDown(h.container.dispose);
    final s = authoredSegment();

    expect(() => adjustCharacterParameter(h.ref, s, 'traffic', 0.1), throwsArgumentError);
    expect(h.container.read(characterVariantProvider(s.id)).isEmpty, isTrue);
  });

  test('chooseCharacterAlternate records the choice; null returns to canon', () {
    final h = harness();
    addTearDown(h.container.dispose);
    final s = authoredSegment();

    chooseCharacterAlternate(h.ref, s, 'alt-bypass');
    expect(h.container.read(characterVariantProvider(s.id)).chosenAlternateId, 'alt-bypass');

    chooseCharacterAlternate(h.ref, s, null);
    expect(h.container.read(characterVariantProvider(s.id)).chosenAlternateId, isNull);
  });

  test('variants are scoped per passage — one Character, two passages, no bleed', () {
    final h = harness();
    addTearDown(h.container.dispose);
    final s1 = authoredSegment();
    final s2 = Segment(
      id: 'seg-2', mode: 'cycling', shape: 'loop', start: const [-105.2, 40.0],
      bands: [Band(attribute: 'climb_m', min: 100.0, max: 900.0, source: 'author')],
      metrics: RouteMetrics(distanceM: 12000.0, climbM: 300.0),
    );

    adjustCharacterParameter(h.ref, s1, 'climb_m', 250.0);

    expect(h.container.read(characterVariantProvider(s1.id)).bandTargets['climb_m'], 250.0);
    expect(h.container.read(characterVariantProvider(s2.id)).isEmpty, isTrue);
  });

  test('resetCharacterVariant drops every personal choice for the passage', () {
    final h = harness();
    addTearDown(h.container.dispose);
    final s = authoredSegment();

    adjustCharacterParameter(h.ref, s, 'climb_m', 300.0);
    chooseCharacterAlternate(h.ref, s, 'alt-bypass');
    expect(h.container.read(characterVariantProvider(s.id)).isEmpty, isFalse);

    resetCharacterVariant(h.ref, s.id);
    expect(h.container.read(characterVariantProvider(s.id)).isEmpty, isTrue);
  });
}

/// The two `WidgetRef` members the provider helpers use, forwarded to a real
/// container. Keeps the helpers testable without pumping a widget.
class _ContainerRef implements WidgetRef {
  _ContainerRef(this._container);

  final ProviderContainer _container;

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
