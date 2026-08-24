// A10 (PRD FR96) — the shipped home region is a constant, not a fetched
// value: these checks just guard the constant's internal consistency (the
// center sits inside the bbox, the outline traces its four corners).
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/home_region.dart';

void main() {
  test('center sits strictly inside the shipped bbox', () {
    expect(HomeRegion.centerLat, greaterThan(HomeRegion.minLat));
    expect(HomeRegion.centerLat, lessThan(HomeRegion.maxLat));
    expect(HomeRegion.centerLon, greaterThan(HomeRegion.minLon));
    expect(HomeRegion.centerLon, lessThan(HomeRegion.maxLon));
    expect(HomeRegion.center, [HomeRegion.centerLon, HomeRegion.centerLat]);
  });

  test('outline traces the four corners of the bbox', () {
    final outline = HomeRegion.outline;
    expect(outline.length, 4);
    expect(outline.map((p) => p[0]).toSet(), {HomeRegion.minLon, HomeRegion.maxLon});
    expect(outline.map((p) => p[1]).toSet(), {HomeRegion.minLat, HomeRegion.maxLat});
  });
}
