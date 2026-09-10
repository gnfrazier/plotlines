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

  test('the enumeration covers the object kinds named in K12 AC, plus what has been added since', () {
    // The eight K12 named — none may quietly disappear.
    expect(
      ReachableObject.values.toSet(),
      containsAll({
        ReachableObject.anchorAttached,
        ReachableObject.anchorUnattached,
        ReachableObject.passage,
        ReachableObject.day,
        ReachableObject.trip,
        ReachableObject.characterNote,
        ReachableObject.groupAssignment,
        ReachableObject.staleItem,
      }),
    );
    // And the whole enumeration — K12's rule is that the enumeration is
    // re-run whenever an object type is added, so a new kind arrives with its
    // path named. Added since K12: `alternate` (issue #324), which an Author
    // now draws on the Route tab's map and finds back on Logistics.
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
        ReachableObject.alternate,
      },
    );
  });

  // #324 — the one object made on one surface and inspected on another.
  test('an alternate is found back on the passage it diverges from', () {
    expect(
      reachabilityRegistry[ReachableObject.alternate]!.surface,
      'logistics_tab_passage_alternates',
    );
  });

  test('attached and unattached anchors both route through the anchors view (N4a)', () {
    expect(reachabilityRegistry[ReachableObject.anchorAttached]!.surface, 'anchors_view');
    expect(reachabilityRegistry[ReachableObject.anchorUnattached]!.surface, 'anchors_view');
  });
}
