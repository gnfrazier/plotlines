// FR142(b) (Story K12) — reachability verified against an enumeration, not
// asserted: every ReachableObject must resolve to a named surface.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('every ReachableObject has a registry entry — nothing ships without its path named', () {
    expect(unreachableObjectTypes(), isEmpty);
    for (final kind in ReachableObject.values) {
      expect(reachabilityRegistry.containsKey(kind), isTrue, reason: '$kind has no reachability target');
    }
  });

  test('every reachability target names a non-empty surface and description', () {
    for (final target in reachabilityRegistry.values) {
      expect(target.surface.trim(), isNotEmpty);
      expect(target.description.trim(), isNotEmpty);
    }
  });

  test('the enumeration covers exactly the object kinds named in K12 AC', () {
    expect(
      ReachableObject.values.toSet(),
      {
        ReachableObject.anchorAttached,
        ReachableObject.anchorUnattached,
        ReachableObject.passage,
        ReachableObject.day,
        ReachableObject.trip,
        ReachableObject.characterNote,
        ReachableObject.groupAssignment,
        ReachableObject.staleItem,
      },
    );
  });

  test('attached and unattached anchors both route through the anchors view (N4a)', () {
    expect(reachabilityRegistry[ReachableObject.anchorAttached]!.surface, 'anchors_view');
    expect(reachabilityRegistry[ReachableObject.anchorUnattached]!.surface, 'anchors_view');
  });
}
