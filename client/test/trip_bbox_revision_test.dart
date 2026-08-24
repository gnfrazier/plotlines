// N1 (PRD FR120) / Author Flows MVP Flow 9 — "shrinking prompts with the
// promoted anchors that would fall outside." This is the pure check behind
// that prompt: a single `anchorsOutsideBbox` call has to double as both "is
// this revision a shrink" and "does it lose anything," per FR120's actual
// invariant (no second extent for analysis, not bbox immutability).
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/domain/trip_bbox_revision.dart';

void main() {
  const original = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);
  const inside = AnchorLocation(id: 'a1', label: 'Inside anchor', point: [-105.2, 40.1]);
  const nearEdge = AnchorLocation(id: 'a2', label: 'Near-edge anchor', point: [-105.11, 40.19]);
  const farOutside = AnchorLocation(id: 'a3', label: 'Far anchor', point: [-104.0, 41.0]);

  test('no anchors means nothing can ever fall outside', () {
    final outside = anchorsOutsideBbox(original, const []);
    expect(outside, isEmpty);
  });

  test('an anchor still inside the proposed box is not flagged', () {
    final outside = anchorsOutsideBbox(original, [inside]);
    expect(outside, isEmpty);
  });

  test('enlarging the box (a pure superset) never excludes an anchor that was already inside', () {
    final enlarged = original.expandToInclude([[-105.0, 40.3]]);
    final outside = anchorsOutsideBbox(enlarged, [inside, nearEdge]);
    expect(outside, isEmpty);
  });

  test('shrinking past an anchor flags exactly that anchor', () {
    // Shrink the box so it no longer reaches the near-edge anchor.
    final shrunk = original.copyWith(maxLon: -105.15, maxLat: 40.15);
    final outside = anchorsOutsideBbox(shrunk, [inside, nearEdge]);
    expect(outside, [nearEdge]);
  });

  test('an anchor already outside the current box stays flagged after any revision', () {
    final outside = anchorsOutsideBbox(original, [farOutside]);
    expect(outside, [farOutside]);
  });

  test('flags every excluded anchor, preserving input order', () {
    final tiny = const TripBbox(minLat: 40.09, minLon: -105.21, maxLat: 40.11, maxLon: -105.19);
    final outside = anchorsOutsideBbox(tiny, [inside, nearEdge, farOutside]);
    expect(outside, [nearEdge, farOutside]);
  });
}
