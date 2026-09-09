// Issue #320 — `markerForNodeKind` is the single `NodeKind` → `NodeMarkerType`
// mapping. The Content tab (and #322's Route-tab node rendering) draw from it,
// so a kind picks one mark and the map never infers a marker from a point's
// position in a list again.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/node.dart';
import 'package:plotlines_client/presentation/map/node_marker_role.dart';

void main() {
  test('start and finish kinds get their own marks (#320)', () {
    expect(markerForNodeKind(NodeKind.start), NodeMarkerType.start);
    expect(markerForNodeKind(NodeKind.finish), NodeMarkerType.finish);
  });

  test('every node kind maps to a marker, and none falls back to plot silently', () {
    const expected = {
      NodeKind.waypoint: NodeMarkerType.waypoint,
      NodeKind.regroup: NodeMarkerType.regroup,
      NodeKind.restStop: NodeMarkerType.rest,
      NodeKind.poi: NodeMarkerType.plot,
      NodeKind.transition: NodeMarkerType.portage,
      NodeKind.start: NodeMarkerType.start,
      NodeKind.finish: NodeMarkerType.finish,
      NodeKind.via: NodeMarkerType.waypoint,
      NodeKind.portageStart: NodeMarkerType.portage,
      NodeKind.portageEnd: NodeMarkerType.portage,
      NodeKind.event: NodeMarkerType.plot,
    };
    // Guards against a new NodeKind being added without a deliberate marker
    // choice here.
    expect(expected.keys.toSet(), NodeKind.values.toSet());
    for (final entry in expected.entries) {
      expect(markerForNodeKind(entry.key), entry.value, reason: '${entry.key}');
    }
  });
}
