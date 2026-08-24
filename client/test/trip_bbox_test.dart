// N1 (PRD FR120) — pure geometry for the trip's authoring bbox: corner
// normalization, containment, the extent readout's width/height, and the
// shrink prompt's "move the bounds to include all three" expansion.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/trip_bbox.dart';

void main() {
  group('TripBbox.fromCorners', () {
    test('normalizes regardless of which corner is passed first', () {
      final a = TripBbox.fromCorners([-105.3, 40.0], [-105.1, 40.2]);
      final b = TripBbox.fromCorners([-105.1, 40.2], [-105.3, 40.0]);
      expect(a, b);
      expect(a.minLat, 40.0);
      expect(a.maxLat, 40.2);
      expect(a.minLon, -105.3);
      expect(a.maxLon, -105.1);
    });

    test('handles a degenerate drag (a straight line) without inverting', () {
      final box = TripBbox.fromCorners([-105.3, 40.0], [-105.3, 40.2]);
      expect(box.minLon, box.maxLon);
      expect(box.minLat, 40.0);
      expect(box.maxLat, 40.2);
    });
  });

  group('contains', () {
    final box = const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);

    test('a point inside the box', () {
      expect(box.contains([-105.2, 40.1]), isTrue);
    });

    test('a point exactly on the boundary counts as inside', () {
      expect(box.contains([-105.3, 40.0]), isTrue);
      expect(box.contains([-105.1, 40.2]), isTrue);
    });

    test('a point outside on any single axis is outside', () {
      expect(box.contains([-105.0, 40.1]), isFalse); // east of maxLon
      expect(box.contains([-105.4, 40.1]), isFalse); // west of minLon
      expect(box.contains([-105.2, 39.9]), isFalse); // south of minLat
      expect(box.contains([-105.2, 40.3]), isFalse); // north of maxLat
    });
  });

  group('center / outline', () {
    final box = const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);

    test('center is the midpoint of both axes', () {
      expect(box.centerLat, closeTo(40.1, 1e-9));
      expect(box.centerLon, closeTo(-105.2, 1e-9));
      expect(box.center, [box.centerLon, box.centerLat]);
    });

    test('outline traces all four corners', () {
      final outline = box.outline;
      expect(outline.length, 4);
      expect(outline.map((p) => p[0]).toSet(), {box.minLon, box.maxLon});
      expect(outline.map((p) => p[1]).toSet(), {box.minLat, box.maxLat});
    });
  });

  group('widthKm / heightKm', () {
    test('a box spanning ~1 degree of latitude is about 111 km tall', () {
      final box = const TripBbox(minLat: 40.0, minLon: -105.2, maxLat: 41.0, maxLon: -105.1);
      expect(box.heightKm, closeTo(111.2, 1.0));
    });

    test('a zero-size box has zero extent', () {
      final box = const TripBbox(minLat: 40.0, minLon: -105.2, maxLat: 40.0, maxLon: -105.2);
      expect(box.widthKm, 0);
      expect(box.heightKm, 0);
    });

    test('width shrinks toward the poles for the same longitude span', () {
      final equator = const TripBbox(minLat: 0.0, minLon: -1.0, maxLat: 0.0, maxLon: 1.0);
      final highLat = const TripBbox(minLat: 60.0, minLon: -1.0, maxLat: 60.0, maxLon: 1.0);
      expect(highLat.widthKm, lessThan(equator.widthKm));
    });
  });

  group('expandToInclude', () {
    final box = const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);

    test('a point already inside leaves the box unchanged', () {
      final expanded = box.expandToInclude([[-105.2, 40.1]]);
      expect(expanded, box);
    });

    test('a point outside grows the box to include it, and nothing else', () {
      final expanded = box.expandToInclude([[-105.05, 40.25]]);
      expect(expanded.maxLon, -105.05);
      expect(expanded.maxLat, 40.25);
      expect(expanded.minLat, box.minLat);
      expect(expanded.minLon, box.minLon);
    });

    test('several points outside on different edges all get included', () {
      final expanded = box.expandToInclude([
        [-105.5, 40.1], // west of minLon
        [-105.2, 40.5], // north of maxLat
      ]);
      expect(expanded.minLon, -105.5);
      expect(expanded.maxLat, 40.5);
      expect(expanded.contains([-105.5, 40.1]), isTrue);
      expect(expanded.contains([-105.2, 40.5]), isTrue);
    });
  });

  group('copyWith', () {
    test('moving one edge only changes that edge', () {
      final box = const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);
      final resized = box.copyWith(maxLat: 40.5);
      expect(resized.maxLat, 40.5);
      expect(resized.minLat, box.minLat);
      expect(resized.minLon, box.minLon);
      expect(resized.maxLon, box.maxLon);
    });

    test('dragging a corner past the opposite edge flips the box instead of inverting it', () {
      final box = const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);
      // Drag the "north" edge below the current south edge.
      final flipped = box.copyWith(maxLat: 39.8);
      expect(flipped.minLat, lessThanOrEqualTo(flipped.maxLat));
      expect(flipped.minLat, 39.8);
      expect(flipped.maxLat, 40.0);
    });
  });

  test('equality and hashCode are value-based', () {
    const a = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);
    const b = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
